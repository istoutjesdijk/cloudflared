"""Assert the invariants of compose.yml that keep routing intact.

Reads `docker compose config --format json` on stdin. A wrong network mode or a
stray published port leaves the container perfectly healthy while every route
through the tunnel returns 502, so these are checked mechanically rather than
by eye.

Usage: docker compose config --format json | python3 ci/check_compose.py <version>
"""

import json
import sys


def main() -> None:
    version = sys.argv[1]
    service = json.load(sys.stdin)["services"]["cloudflared"]
    errors = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            errors.append(message)

    check(
        service.get("network_mode") == "host",
        f"network_mode is {service.get('network_mode')!r}, expected 'host'",
    )
    check(
        not service.get("ports"),
        f"compose publishes ports {service.get('ports')!r}; it must publish none",
    )

    command = service.get("command")
    if isinstance(command, list):
        command = " ".join(command)
    check(
        command == "tunnel --no-autoupdate run",
        f"command is {command!r}, expected 'tunnel --no-autoupdate run'",
    )

    image = service.get("image", "")
    check(
        image.endswith(f":{version}"),
        f"image is {image!r}, expected it to end with ':{version}'",
    )

    test = service.get("healthcheck", {}).get("test") or []
    check(
        test[:1] == ["CMD"] and len(test) > 1,
        f"healthcheck test is {test!r}, expected an exec-form CMD list",
    )

    if errors:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)

    print(f"image: {image}")
    print(f"healthcheck: {' '.join(test[1:])}")


if __name__ == "__main__":
    main()
