## Environment 

environment selection is based on value  `environment_type`.

standard configuration is loaded keyed by the environment_name.  For example all values in:

```yaml
prod:
  dashboard_static_ip: 35.193.198.6
  dashboard_url: dashboard.stardust.es.net
  reserved_ip: grafana-ingress-ip
  domain_urls:
    - dashboard.stardust.es.net
    - gf.gc1.prod.stardust.es.net
```

If the environment_type is set to 'prod' then all keys in prod will be exposed in the root level.  `{{ dashboard_url }}` can be used without knowing what the env key-space is.

## Secret / Vaults.

For vaults we use the same pattern but to avoid collisions we're prefacing all the environments with the prefix `secret_`.  In this case for prod we'll have a: 

```yaml
secret_prod:
  database_password: SomeSecretValue
  elastic_admin: esnet-admin
  elastic_admin_pwd: superSensitiveData
```

## Behavior
We attempt the load the ENV for the specified environment and secret-ENV.  If neither are defined, the assumption is that no data is needed to be specified per env.  

Secrets can be skipped via `--skip-tags secret`

