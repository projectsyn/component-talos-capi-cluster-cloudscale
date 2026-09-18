local kap = import 'lib/kapitan.libjsonnet';
local tuppr = import 'lib/tuppr.libsonnet';

local capi = import 'lib/capi-core.libsonnet';
local capi_talos = import 'lib/capi-provider-talos.libsonnet';

local utils = import 'utils.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.talos_capi_cluster_cloudscale;

local tcp = capi_talos.TalosControlPlane('');
local md = capi.MachineDeployment('');

local talosUpgrade = tuppr.TalosUpgrade('cluster') {
  metadata+: {
    annotations+: {
      // Ensure this is applied after the CAPI resources. This should ensure
      // that Tuppr never tries to start a Talos patch or minor upgrade when
      // we also replace machines (e.g. K8s upgrade or similar).
      'argocd.argoproj.io/sync-wave': '10',
    },
  },
  spec+: {
    drain: {
      enabled: true,
    },
    talos: {
      version:
        'v%(major)s.%(minor)s.%(patch)s' %
        utils.validateTalosVersion(params.talosVersion),
    },
    healthChecks: [
      // NOTE(sg): This should wait for control plane health before doing Talos
      // upgrades.
      {
        apiVersion: tcp.apiVersion,
        kind: tcp.kind,
        namespace: params.namespace,
        // TODO(sg): figure out good timeout for this.
        timeout: '30m',
        expr: |||
          status.conditions.exists(
            c, c.type == "EtcdClusterHealthyCondition" && c.status == "True"
          ) && status.conditions.exists(
            c, c.type == "ControlPlaneComponentsHealthy" && c.status == "True"
          ) && status.conditions.exists(
            c, c.type == "Ready" && c.status == "True"
          ) && status.conditions.exists(
            c, c.type == "Available" && c.status == "True"
          )
        |||,
      },
      // NOTE(sg): This should wait for node creations & replacements to
      // complete before doing Talos upgrades.
      {
        apiVersion: md.apiVersion,
        kind: md.kind,
        namespace: params.namespace,
        // TODO(sg): figure out good timeout for this.
        timeout: '30m',
        expr: |||
          status.phase == "Running"
          && status.conditions.exists(c, c.type == "Available" && c.status == "True")
        |||,
      },
    ],
  },
};

if std.member(inv.applications, 'tuppr') then {
  tuppr_talosupgrade: talosUpgrade,
} else std.trace(
  'Not rendering Tuppr TalosUpgrade because component-tuppr is missing.',
  {}
)
