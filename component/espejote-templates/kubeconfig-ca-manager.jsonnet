local esp = import 'espejote.libsonnet';

local config = import 'capi-kubeconfig-ca-manager/config.json';

local kubeconfig =
  local kcs = esp.context().kubeconfig;
  assert std.length(kcs) == 1 : 'Expected kubeconfig context to have length 1';
  assert std.objectHas(kcs[0].data, 'value') : 'Expected kubeconfig secret to have field `value`';
  std.parseYaml(std.base64Decode(kcs[0].data.value));

local user_kubeconfig =
  local contextName = 'oidc@%s' % kubeconfig.clusters[0].name;
  {
    apiVersion: 'v1',
    kind: 'Config',
    clusters: [
      kubeconfig.clusters[0] {
        cluster+: {
          [if config.apiURL != '' then 'server']:
            'https://%s:6443' % config.apiURL,
        },
      },
    ],
    contexts: [
      {
        context: {
          cluster: kubeconfig.clusters[0].name,
          user: 'oidc',
        },
        name: contextName,
      },
    ],
    'current-context': contextName,
    users: [
      {
        name: 'oidc',
        user: {
          exec: {
            apiVersion: 'client.authentication.k8s.io/v1beta1',
            args: [
              'oidc-login',
              'get-token',
              '--oidc-issuer-url=%s' % config.oidcIssuerURL,
              '--oidc-client-id=%s' % config.oidcClientId,
              '--oidc-extra-scope=email offline_access profile openid',
            ],
            command: 'kubectl',
            interactiveMode: 'IfAvailable',
            provideClusterInfo: false,
          },
        },
      },
    ],
  };
local index_html = importstr 'capi-kubeconfig-ca-manager/index.html';
local caddy_json = importstr 'capi-kubeconfig-ca-manager/caddy.json';
local confighash = std.sha256(
  std.manifestJsonMinified(user_kubeconfig) + index_html + caddy_json
);

[
  {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: {
      name: config.dynfactConfigMapName,
      namespace: 'syn',
      labels: {
        'app.kubernetes.io/managed-by': 'espejote',
        'steward.syn.tools/include-facts': '',
      },
    },
    data: {
      facts: std.manifestJsonMinified({
        talosAPICertificateAuthorityData:
          kubeconfig.clusters[0].cluster['certificate-authority-data'],
      }),
    },
  },
  {
    apiVersion: 'v1',
    kind: 'ConfigMap',
    metadata: {
      name: config.caddyResourceName,
      namespace: config.namespace,
    },
    data: {
      // manifestYamlDoc doesn't add a trailing newline, so we do it
      // ourselves.
      kubeconfig: std.manifestYamlDoc(user_kubeconfig, quote_keys=false) + '\n',
      'index.html': index_html,
      'caddy.json': caddy_json,
    },
  },
  esp.applyOptions(
    {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: config.caddyResourceName,
        namespace: config.namespace,
      },
      spec: {
        template: {
          metadata: {
            annotations: {
              ['%s.syn.tools/config-hash' % config.caddyResourceName]: confighash,
            },
          },
        },
      },
    },
    fieldManagerSuffix=':reloader',
    force=true,
  ),
]
