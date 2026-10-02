# CentOS Messaging SIG patch series

The three subdirectories contain every `Patch:` entry from these CentOS
Messaging SIG `c10s` specs:

- `rabbitmq/`: [`rabbitmq-server.spec`](https://gitlab.com/CentOS/messaging/rpms/rabbitmq-server/-/blob/dd381575c04ea1e4c7b77c2253d221e03ad32231/rabbitmq-server.spec), commit
  `dd381575c04ea1e4c7b77c2253d221e03ad32231` (6 patches).
- `otp/`: [`erlang.spec`](https://gitlab.com/CentOS/messaging/rpms/erlang/-/blob/a131da91b10624199ad49adee66c82cd27a06ede/erlang.spec), commit
  `a131da91b10624199ad49adee66c82cd27a06ede` (23 patches).
- `elixir/`: [`elixir.spec`](https://gitlab.com/CentOS/messaging/rpms/elixir/-/blob/00245c94a4e8fff43e882980c4442a9fb274aa7b/elixir.spec), commit
  `00245c94a4e8fff43e882980c4442a9fb274aa7b` (3 patches).

The RabbitMQ and OTP specs apply patches with `%autosetup -p1`. The Elixir
spec's explicit order is preserved in `build-rabbitmq.sh`. All patches are
applied to their pinned source trees before building. Versions are recorded in
the project-level `sources.txt`.
