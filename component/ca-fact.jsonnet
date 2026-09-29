local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.talos_capi_cluster_cloudscale;
local ca_secret_name = '%s-ca' % params.clusterName;

local syn_namespace = std.get(std.get(inv.parameters, 'steward', {}), 'namespace', 'syn');

local sa = kube.ServiceAccount('cluster-ca-dynamic-fact-manager') {
  metadata+: {
    namespace: params.namespace,
  },
};

local syn_role = kube.Role('cluster:ca-dynamic-fact-manager') {
  metadata+: {
    namespace: 'syn',
  },
  rules: [
    {
      apiGroups: [ '' ],
      resources: [ 'configmaps' ],
      verbs: [ 'get', 'list', 'watch' ],
    },
    {
      apiGroups: [ '' ],
      resources: [ 'configmaps' ],
      resourceNames: [ 'capi-ca-fact' ],
      verbs: [ 'create', 'update', 'patch' ],
    },
  ],
};

local role = kube.Role('cluster:ca-dynamic-fact-manager') {
  metadata+: {
    namespace: params.namespace,
  },
  rules: [
    {
      apiGroups: [ '' ],
      resources: [ 'secrets' ],
      resourceNames: [ ca_secret_name ],
      verbs: [ 'get', 'list', 'watch' ],
    },
  ],
};

local syn_rolebinding =
  kube.RoleBinding('cluster:ca-dynamic-fact-manager') {
    metadata+: {
      namespace: syn_namespace,
    },
    roleRef_: syn_role,
    subjects_: [ sa ],
  };

local rolebinding =
  kube.RoleBinding('cluster:ca-dynamic-fact-manager') {
    metadata+: {
      namespace: params.namespace,
    },
    roleRef_: role,
    subjects_: [ sa ],
  };


local mr = esp.managedResource('cluster-ca-dynamic-fact', params.namespace) {
  spec: {
    // Set force=true so we can take ownership of previously manually edited
    // fields in `data`.
    applyOptions: { force: true },
    serviceAccountRef: { name: sa.metadata.name },
    context: [
      {
        name: 'source',
        resource: {
          apiVersion: 'v1',
          kind: 'Secret',
          name: ca_secret_name,
        },
      },
    ],
    triggers: [
      {
        name: 'source',
        watchContextResource: {
          name: 'source',
        },
      },
      {
        name: 'target',
        watchResource: {
          apiVersion: 'v1',
          kind: 'ConfigMap',
          namespace: syn_namespace,
          name: 'capi-ca-fact',
        },
      },
    ],
    template: importstr 'espejote-templates/manage-ca-fact.jsonnet',
  },
};

if std.member(inv.applications, 'espejote') then {
  cluster_ca_dynamic_fact: [ sa, role, rolebinding, syn_role, syn_rolebinding, mr ],
} else std.trace(
  'Not rendering Espejote-managed CA fact because component-espejote is missing.',
  {}
)
