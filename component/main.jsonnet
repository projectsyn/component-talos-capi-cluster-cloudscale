local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.talos_capi_cluster_cloudscale;

local cloudscaleImageSlug = 'custom:%s' % params.cloudscale.customImageSlug;

local resourceSetLabelKey = 'talos-capi-cluster-cloudscale.syn.tools/bootstrap';

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
    },
  },
  cluster: {
    // TODO(sg): document how to inject CCM manifests during bootstrap
    externalCloudProvider: {
      enabled: true,
    },
  },
};

local capiTalosControlPlane = params.talosControlPlane {
  apiVersion: 'controlplane.cluster.x-k8s.io/v1alpha3',
  kind: 'TalosControlPlane',
  metadata+: std.get(params.talosControlPlane, 'metadata', {}) {
    name: params.clusterName,
    namespace: params.namespace,
  },
  spec+: params.talosControlPlane.spec {
    version: params.kubernetesVersion,
    infrastructureTemplate: {
      apiVersion: 'infrastructure.cluster.x-k8s.io/v1beta2',
      kind: 'CloudscaleMachineTemplate',
      name: capiCloudscaleMachineTemplateControlPlane.metadata.name,
    },
    controlPlaneConfig: {
      controlplane: {
        generateType: 'controlplane',
        talosVersion: params.talosVersion,
        hostname: {
          // we want to use the VM name defined by the cloudscale CAPI
          // provider.
          source: 'InfrastructureName',
        },
        strategicPatches: [
          std.manifestJsonMinified(talosStrategicPatch {
            machine+: {
              install+: {
                // TODO(sg): do installers for custom schematic ids even exist?
                // TODO(sg): figure out the new way to do this
                image: 'factory.talos.dev/openstack-installer/%(schematic_uuid)s:v%(version)s' % {
                  schematic_uuid: params.talosSchematicUUID,
                  version: params.talosVersion,
                },
              },
            },
          }),
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
          talosVersion: params.talosVersion,
          hostname: {
            source: 'InfrastructureName',
          },
          strategicPatches: [
            std.manifestJsonMinified(talosStrategicPatch),
          ],
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
          version: params.kubernetesVersion,
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
