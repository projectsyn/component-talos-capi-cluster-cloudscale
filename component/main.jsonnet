local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

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

local capiCloudscaleCluster = {
  apiVersion: 'infrastructure.cluster.x-k8s.io/v1beta2',
  kind: 'CloudscaleCluster',
  metadata+: std.get(params.cloudscaleCluster, 'metadata', {}) {
    name: params.clusterName,
    namespace: params.namespace,
  },
  spec+: params.cloudscaleCluster.spec {
    networks: [
      {
        name: params.cloudscale.privateNetwork.name,
        uuid: params.cloudscale.privateNetwork.uuid,
      },
    ],
  },
};

local capiCloudscaleMachineTemplateControlPlane = {
  apiVersion: 'infrastructure.cluster.x-k8s.io/v1beta2',
  kind: 'CloudscaleMachineTemplate',
  metadata+: {
    name: nameWithHash('%s-control-plane' % params.clusterName, $.spec),
    namespace: params.namespace,
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

local capiTalosControlPlane = {
  apiVersion: 'controlplane.cluster.x-k8s.io/v1beta1',
  kind: 'TalosControlPlane',
  metadata: std.get(params.talosControlPlane, 'metadata', {}) {
    name: params.clusterName,
    namespace: params.namespace,
  },
  spec+: params.talosControlPlane.spec {
    replicas: params.controlPlane.count,
    version: kubernetesVersion,
    machineTemplate: {
      spec: {
        infrastructureRef: {
          apiGroup: 'infrastructure.cluster.x-k8s.io',
          kind: 'CloudscaleMachineTemplate',
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
        strategicPatches: strategicPatches + [
          std.manifestJsonMinified(patch)
          for patch in std.objectValues(params.talosControlPlane.strategicPatches)
        ],
      },
    },
  },
};

// NOTE(sg): figure out if this is even needed after initial bootstrap
local capiClusterResourceSetBootstrap = {
  apiVersion: 'addons.cluster.x-k8s.io/v1beta2',
  kind: 'ClusterResourceSet',
  metadata: {
    name: 'cloudscale-bootstrap-%s' % params.clusterName,
    namespace: params.namespace,
  },
  spec: {
    strategy: 'ApplyOnce',
    clusterSelector: {
      matchLabels: {
        [resourceSetLabelKey]: 'cloudscale',
      },
    },
    resources: [
      // NOTE(sg): the configmaps are externally generated for bootstrap
      {
        name: '%s-ccm' % params.clusterName,
        kind: 'ConfigMap',
      },
      {
        name: '%s-cilium' % params.clusterName,
        kind: 'ConfigMap',
      },
    ],
  },
};

local capiWorkerGroup(name) =
  local talosConfigTemplate = {
    apiVersion: 'bootstrap.cluster.x-k8s.io/v1alpha3',
    kind: 'TalosConfigTemplate',
    metadata: {
      name: nameWithHash(name, $.spec),
      namespace: params.namespace,
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
  local cloudscaleMachineTemplate = {
    apiVersion: 'infrastructure.cluster.x-k8s.io/v1beta2',
    kind: 'CloudscaleMachineTemplate',
    metadata: {
      name: nameWithHash(name, $.spec),
      namespace: params.namespace,
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
  local machineDeployment = {
    apiVersion: 'cluster.x-k8s.io/v1beta2',
    kind: 'MachineDeployment',
    metadata: {
      name: name,
      namespace: params.namespace,
    },
    spec: {
      clusterName: params.clusterName,
      replicas: params.workerGroups[name].count,
      deletion: {
        // TODO(sg): decide how we want to expose useful config options.
        order: std.get(params.workerGroups[name], 'deletionOrder', 'Oldest'),
      },
      selector: {
        matchLabels: null,
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
              name: talosConfigTemplate.metadata.name,
              apiGroup: 'bootstrap.cluster.x-k8s.io',
              kind: 'TalosConfigTemplate',
            },
          },
          infrastructureRef: {
            name: cloudscaleMachineTemplate.metadata.name,
            apiGroup: 'infrastructure.cluster.x-k8s.io',
            kind: 'CloudscaleMachineTemplate',
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

local capiCluster = params.cluster {
  apiVersion: 'cluster.x-k8s.io/v1beta2',
  kind: 'Cluster',
  metadata+: {
    name: params.clusterName,
    namespace: params.namespace,
    labels+: {
      [resourceSetLabelKey]: 'cloudscale',
    },
  },
  spec+: {
    infrastructureRef: {
      apiGroup: 'infrastructure.cluster.x-k8s.io',
      kind: 'CloudscaleCluster',
      name: capiCloudscaleCluster.metadata.name,
    },
    controlPlaneRef: {
      apiGroup: 'controlplane.cluster.x-k8s.io',
      kind: 'TalosControlPlane',
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
      capiClusterResourceSetBootstrap,
    ],
  } + {
    ['worker_group_%s' % wg.name]: wg.resources
    for wg in com.generateResources(params.workerGroups, capiWorkerGroup)
  }
