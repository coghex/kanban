# A container that boots systemd as PID 1, so the drainer's Linux lifecycle can
# be exercised against a real user manager rather than against generated files.
#
# `docs/linux_portability_design.md` decision D-1 fixes that standard: no Linux
# host is known to exist for this project, so the Linux claim is
# container-verified. A job that only asserted on the unit file it had just
# written would prove the writer and nothing else — not that systemd loads that
# unit, not that `systemctl --user start` brings the drainer up, and not that a
# stop settles it. This image exists so the assertions can be about durable
# state.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        dbus-user-session \
        git \
        python3 \
        systemd \
        systemd-sysv \
    && rm -rf /var/lib/apt/lists/*

# An ordinary unprivileged account, because the drainer installs *user* units
# and every path it writes is under that user's own home. The uid is pinned
# rather than allocated: `lifecycle-check.service` names `user@1001.service`
# and `/run/user/1001`, and a base image that shifted the next free uid would
# otherwise leave the check ordered after a manager that does not exist.
#
# Lingering is enabled by creating the marker directly rather than through
# `loginctl`, which needs a running manager that does not exist at build time.
# It is what makes `user@1001.service` start without a login session, which is
# the whole difference between a usable `systemctl --user` and an unusable one.
RUN useradd --create-home --uid 1001 --shell /bin/bash drainer \
    && mkdir -p /var/lib/systemd/linger \
    && touch /var/lib/systemd/linger/drainer

COPY . /workspace
RUN chown -R drainer:drainer /workspace

# The check is a unit rather than the container command, so it can be ordered
# after the user manager it drives and so its exit status survives in a form
# `systemctl start` reports back. It carries no [Install] section, so booting
# this image runs nothing on its own.
COPY .github/systemd-lifecycle/lifecycle-check.service /etc/systemd/system/lifecycle-check.service

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/lib/systemd/systemd"]
