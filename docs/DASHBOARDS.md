<sub>[← Documentation](README.md) · Before: [Discord](DISCORD.md) · Next: [API reference →](API.md)</sub>

# Homarr and other dashboards

A dashboard such as Homarr, a script or Home Assistant cannot sign in the way a person does: it sends one fixed header with
every request, for months. DCS has two things for that.

| | What it opens | Where you make it |
|---|---|---|
| **API key** | Everything a viewer may read (`read`), or that plus start, stop, restart and update (`operate`) | Secrets > **API keys** |
| **Dashboard feed token** | Two read-only addresses and nothing else: `/feed/summary` and `/feed/crowdsec` | Secrets > **Dashboard feed** |

Use the feed token for a board that only shows numbers. Use an API key when the board should list stacks and containers, or
have buttons.

## API keys

Make one under **Secrets > API keys**: say what it is for, choose `read` or `operate`, and optionally when it expires. The key
(`dcs_` and forty characters) is shown once; DCS keeps a hash of it. Send it in either header:

```
Authorization: Bearer dcs_…
X-API-Key: dcs_…
```

- A `read` key may call every `GET` a viewer may, and nothing else.
- An `operate` key may also do what a bot account may: start, stop, restart and update stacks and containers, deploy a
  template, run a backup or a schedule.
- A key is never an admin: accounts, sessions, secrets, the terminal, files, settings and the keys themselves stay closed.
- The list shows when a key was last used. *Remove* ends it at once. The audit log names the key (`key:Homarr`).

From a script:

```bash
curl -s -H "X-API-Key: $DCS_KEY" http://my-server:9876/summary | jq .
curl -s -X POST -H "X-API-Key: $DCS_KEY" http://my-server:9876/stacks/media-services/restart    # an operate key
```

`GET /summary` is the server at a glance (and the UPS when `UPS_ENABLED` is on: `system.ups` has the charge, the minutes left, the load in watts, and whether it is on battery): the version, stacks up of total, containers running of total, and the machine
(processor, memory, disk, the graphics cards: `system.gpu` is the busiest one, `system.gpus` every NVIDIA, AMD and
Intel card, with `asleep` for an AMD card the driver has powered down).

## Homarr custom widgets

In Homarr 1.x a custom widget asks an address and draws the answer. For DCS:

| Field | Value |
|---|---|
| URL | `http://<the server's address>:9876/summary` (Homarr asks from its container: use the server's LAN address, not `localhost`) |
| Authentication | *API key in header*, header name `X-API-Key`, the key as the secret (or *Bearer token*) |
| Display | *Custom JSX*, for example the template below |

```jsx
<Stack gap={4}>
  <Title order={3}>{data.name}</Title>
  <Text size="sm">DCS v{data.version} · {data.stacks_up} of {data.stacks_total} stacks up · {data.containers.running} of {data.containers.total} containers running</Text>
  <Progress value={data.system.cpu.percent} size="sm" />
  <Progress value={data.system.memory.percent} size="sm" color="pink" />
</Stack>
```

A button that restarts a stack is a widget with display *Action button*, method `POST`, the URL
`http://<server>:9876/stacks/<name>/restart` and an `operate` key.

Other addresses a board finds useful, all with a `read` key: `/stacks` (every stack with its containers), `/containers`,
`/health`, `/images/check-updates`, `/crowdsec/metrics` (detections, countries, the map's points).

## Home Assistant

A REST sensor with the key in its headers:

```yaml
rest:
  - resource: http://my-server:9876/summary
    headers:
      X-API-Key: !secret dcs_key
    scan_interval: 60
    sensor:
      - name: DCS stacks up
        value_template: "{{ value_json.stacks_up }}"
      - name: DCS processor
        value_template: "{{ value_json.system.cpu.percent }}"
        unit_of_measurement: "%"
```
