local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local capi = import 'lib/capi-core.libsonnet';
local capcs = import 'lib/capi-provider-cloudscale.libsonnet';
local capi_talos = import 'lib/capi-provider-talos.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.talos_capi_cluster_cloudscale;

local validateTalosVersion(tver) =
  local parts = std.split(tver, '.');
  assert std.length(parts) == 2 : 'Expected Talos version to contain exacty 1 dot';
  local major = std.parseJson(parts[0]);
  local minor = std.parseJson(parts[1]);
  if !std.isInteger(major) || !std.isInteger(minor) then
    error "Expected Talos version to be '<major>.<minor>', got '%s'" % tver
  else
    {
      major: major,
      minor: minor,
    };

local cloudscaleImageSlug = 'custom:%s' % params.cloudscale.customImageSlug;

local resourceSetLabelKey = 'talos-capi-cluster-cloudscale.syn.tools/bootstrap';

local kubernetesVersion =
  local formatter =
    if std.startsWith(params.kubernetesVersion, 'v') then
      '%s'
    else
      std.trace(
        "CAPI expects kubernetesVersion to be prefixed with 'v', adjusting %s"
        % params.kubernetesVersion,
        'v%s'
      );
  formatter % params.kubernetesVersion;

// TODO(sg): figure out which resources need to have `nameWithHash()`
local nameWithHash(name, spec, length=16) =
  '%s-%s' % [
    name,
    std.sha256(std.manifestJsonMinified(spec))[:length],
  ];

local filteredMetadata(meta) = {
  [k]: meta[k]
  for k in std.objectFields(meta)
  if !std.member([ 'name', 'namespace' ], k)
};

local capiCloudscaleCluster = capcs.CloudscaleCluster(params.clusterName) {
  metadata+: filteredMetadata(std.get(params.cloudscaleCluster, 'metadata', {})),
  spec+: params.cloudscaleCluster.spec {
    networks: [
      {
        name: params.cloudscale.privateNetwork.name,
        uuid: params.cloudscale.privateNetwork.uuid,
      },
    ],
  },
};

local capiCloudscaleMachineTemplateControlPlane = capcs.CloudscaleMachineTemplate(params.clusterName) {
  metadata+: {
    name: nameWithHash('%s-control-plane' % params.clusterName, $.spec),
  },
  spec: {
    template: {
      spec: {
        flavor: params.controlPlane.flavor,
        image: cloudscaleImageSlug,
        rootVolumeSize: params.controlPlane.rootVolumeSize,
        serverGroup: {
          name: '%s-control-plane' % params.clusterName,
        },
        interfaces: [
          {
            network: params.cloudscale.privateNetwork.name,
          },
        ],
      },
    },
  },
};

local talosStrategicPatch = {
  machine: {
    network: {
      interfaces: [
        {
          deviceSelector: {
            physical: true,
          },
          dhcp: true,
        },
      ],
    },
    install: {
      disk: '/dev/sda',
      wipe: true,
      // NOTE(sg): image is required by Tuppr in order to compute the update
      image: 'factory.talos.dev/openstack-installer/%(schematic_uuid)s:v%(version)s' % {
        schematic_uuid: params.talosSchematicUUID,
        version:
          '%(major)s.%(minor)s.0' % validateTalosVersion(params.talosVersion),
      },
    },
    kubelet: {
      extraArgs: {
        // NOTE(sg): required for metrics-server, but requires a mechanism to
        // approve Kubelet CSRs. We currently use
        // https://github.com/alex1989hu/kubelet-serving-cert-approver
        'rotate-server-certificates': true,
      },
    },
  },
  // TODO(sg): figure out if this section is really needed for worker groups.
  cluster: {
    [if params.apiURL != '' then 'apiServer']: {
      certSANs: [ params.apiURL ],
    },
    // TODO(sg): document how to inject CCM manifests during bootstrap
    externalCloudProvider: {
      enabled: true,
    },
    network: {
      cni: {
        // valid values: `flannel`, `custom`, `none`.
        // `custom` uses custom manifests provided via `cni.urls`
        // `none` indicates externally provisioned & managed CNI
        // we currently assume that we'll always deploy custom CNIs via CAPI
        // resourcesets.
        [if params.cni != 'flannel' then 'name']: 'none',
      },
    },
    proxy: {
      disabled: if params.cni == 'cilium' then
        inv.parameters.cilium.cilium_helm_values.kubeProxyReplacement == 'true'
      else
        std.trace('Not disabling kube-proxy for CNI %s' % params.cni, false),
    },
  },
};

// TODO(sg): does order matter here?
local strategicPatches = [
  std.manifestJsonMinified(patch)
  for patch in std.objectValues(params.talosStrategicPatches)
] + [
  std.manifestJsonMinified(talosStrategicPatch),
];

local authenticationConfiguration = {
  apiVersion: 'apiserver.config.k8s.io/v1',
  kind: 'AuthenticationConfiguration',
  jwt: std.filter(
    function(it) it != null,
    std.objectValues(params.kubernetesApiServer.authenticationConfigurationJWT)
  ),
  //TODO(sg): do we want to allow configuring other top-level fields? are
  //there even any other top-level fields?
};

local authenticationPatch =
  if std.length(authenticationConfiguration.jwt) > 0 then
    local filedir = '/var/config/kubernetes/kube-apiserver';
    local filepath = '%s/syn-authentication-configuration.yaml' % filedir;
    [
      std.manifestJsonMinified({
        machine: {
          files: [
            {
              content: std.manifestYamlDoc(authenticationConfiguration),
              permissions: std.parseOctal('0644'),
              path: filepath,
              op: 'create',
            },
          ],
        },
        cluster: {
          apiServer: {
            extraArgs: {
              'authentication-config': filepath,
            },
            extraVolumes: [
              {
                hostPath: filedir,
                mountPath: filedir,
                readonly: true,
              },
            ],
          },
        },
      }),
    ] else [];

// NOTE(sg): kubernetesTalosAPIAccess can only be configured on control plane
// nodes, worker provisioning fails with the following error if
// kubernetesTalosAPIAccess is present in the machine configuration:
//
// failed to validate config acquired via platform openstack: 1 error occurred:
//  * v1alpha1.Config: 1 error occurred:
//    * feature Kubernetes Talos API Access can only be enabled on control plane machines
local tupprAccessPatch = {
  machine: {
    features: {
      kubernetesTalosAPIAccess: {
        enabled: true,
        allowedKubernetesNamespaces: [
          'syn-tuppr',
        ],
        allowedRoles: [ 'os:admin' ],
      },
    },
  },
};

local controlPlaneStrategicPatches = [
  std.manifestJsonMinified(patch)
  for patch in std.objectValues(params.talosControlPlane.strategicPatches)
] + authenticationPatch + [
  std.manifestJsonMinified(tupprAccessPatch),
];

local capiTalosControlPlane = capi_talos.TalosControlPlane(params.clusterName) {
  metadata+: filteredMetadata(std.get(params.talosControlPlane, 'metadata', {})),
  spec+: params.talosControlPlane.spec {
    replicas: params.controlPlane.count,
    version: kubernetesVersion,
    machineTemplate: {
      spec: {
        infrastructureRef: {
          apiGroup: capcs.apiGroup,
          kind: capiCloudscaleMachineTemplateControlPlane.kind,
          name: capiCloudscaleMachineTemplateControlPlane.metadata.name,
        },
      },
    },
    controlPlaneConfig+: {
      controlplane+: {
        generateType: 'controlplane',
        talosVersion: '%(major)s.%(minor)s' % validateTalosVersion(params.talosVersion),
        hostname: {
          // we want to use the VM name defined by the cloudscale CAPI
          // provider.
          source: 'InfrastructureName',
        },
        strategicPatches: strategicPatches + controlPlaneStrategicPatches,
      },
    },
  },
};

local capiWorkerGroup(name) =
  local talosConfigTemplate = capi_talos.TalosConfigTemplate(name) {
    metadata+: {
      name: nameWithHash(name, $.spec),
    },
    spec: {
      template: {
        spec: {
          generateType: 'join',
          talosVersion: '%(major)s.%(minor)s' % validateTalosVersion(params.talosVersion),
          hostname: {
            source: 'InfrastructureName',
          },
          strategicPatches: strategicPatches,
        },
      },
    },
  };
  local cloudscaleMachineTemplate = capcs.CloudscaleMachineTemplate(name) {
    metadata+: {
      name: nameWithHash(name, $.spec),
    },
    spec: {
      template: {
        spec: {
          flavor: params.workerGroups[name].flavor,
          image: cloudscaleImageSlug,
          rootVolumeSize: params.workerGroups[name].rootVolumeSize,
          serverGroup: {
            name: name,
          },
          interfaces: [
            {
              network: params.cloudscale.privateNetwork.name,
            },
          ],
        },
      },
    },
  };
  local mdDeletionOrder =
    local valOrDefault = std.get(params.workerGroups[name], 'deletionOrder', 'Oldest');
    local validDeletionOrders = [ 'Newest', 'Oldest', 'Random' ];
    assert
      std.member(validDeletionOrders, valOrDefault)
      : "Invalid value '%s' for deletion order for machinedeployment '%s': " % [ valOrDefault, name ]
        + 'valid options are %s' % validDeletionOrders;
    valOrDefault;
  local machineDeployment = capi.MachineDeployment(name) {
    spec: {
      clusterName: params.clusterName,
      replicas: params.workerGroups[name].count,
      deletion: {
        // TODO(sg): decide how we want to expose useful config options.
        order: std.get(params.workerGroups[name], 'deletionOrder', 'Oldest'),
      },
      template: std.get(params.workerGroups[name], 'template', {}) {
        metadata: {
          labels+: {
            'node-role.kubernetes.io/worker': '',
          },
        },
        spec: {
          clusterName: params.clusterName,
          version: kubernetesVersion,
          bootstrap: {
            configRef: {
              apiGroup: capi_talos.bootstrapApiGroup,
              kind: talosConfigTemplate.kind,
              name: talosConfigTemplate.metadata.name,
            },
          },
          infrastructureRef: {
            apiGroup: capcs.apiGroup,
            kind: cloudscaleMachineTemplate.kind,
            name: cloudscaleMachineTemplate.metadata.name,
          },
        },
      },
    },
  };

  // NOTE(sg): we're slightly abusing com.generateResources() below. The
  // function doesn't really support rendering multiple objects instead of
  // rendering a single object and merging the parameter dict values into it.
  {
    name: name,
    resources: [
      machineDeployment,
      cloudscaleMachineTemplate,
      talosConfigTemplate,
    ],
  };

local capiCluster = capi.Cluster(params.clusterName) {
  metadata+: filteredMetadata(std.get(params.cluster, 'metadata', {})) {
    labels+: {
      [resourceSetLabelKey]: 'cloudscale',
    },
  },
  spec+: std.get(params.cluster, 'spec', {}) {
    infrastructureRef: {
      apiGroup: capcs.apiGroup,
      kind: capiCloudscaleCluster.kind,
      name: capiCloudscaleCluster.metadata.name,
    },
    controlPlaneRef: {
      apiGroup: capi_talos.controlPlaneApiGroup,
      kind: capiTalosControlPlane.kind,
      name: capiTalosControlPlane.metadata.name,
    },
  },
};

if params.cni == 'cilium' && !std.member(inv.applications, 'cilium') then
  error 'Component talos-capi-cluster-cloudscale expects that component-cilium is present when parameter cni=cilium'
else
  {
    capi_cluster: [
      capiCluster,
      capiCloudscaleCluster,
      capiCloudscaleMachineTemplateControlPlane,
      capiTalosControlPlane,
    ],
  } + {
    ['worker_group_%s' % wg.name]: wg.resources
    for wg in com.generateResources(params.workerGroups, capiWorkerGroup)
  }
