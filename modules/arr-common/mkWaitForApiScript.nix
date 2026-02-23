{
  lib,
  pkgs,
}:
serviceName: serviceConfig:
pkgs.writeShellScript "${serviceName}-wait-for-api" (
  let
    mkSecureCurl = import ../../lib/mk-secure-curl.nix { inherit lib pkgs; };
    capitalizedName =
      lib.toUpper (builtins.substring 0 1 serviceName) + builtins.substring 1 (-1) serviceName;
  in
  ''
    BASE_URL="http://${serviceConfig.hostConfig.apiHost}:${builtins.toString serviceConfig.hostConfig.port}${serviceConfig.hostConfig.urlBase}/api/${serviceConfig.apiVersion}"

    echo "Waiting for ${capitalizedName} API to be available..."
    for i in {1..90}; do
      if ${
        mkSecureCurl serviceConfig.apiKey {
          url = "$BASE_URL/system/status";
          # --max-time 10: prevent curl from hanging indefinitely when the server
          # has bound the TCP port but hasn't initialized its HTTP layer yet.
          # Without this, curl waits forever on the first connection and the loop
          # never advances (each iteration is blocked, not just sleeping 1s).
          extraArgs = "-f --max-time 10";
        }
      } >/dev/null 2>&1; then
        echo "${capitalizedName} API is available"
        exit 0
      fi
      echo "Waiting for ${capitalizedName} API... ($i/90)"
      sleep 1
    done

    echo "${capitalizedName} API not available after 90 seconds" >&2
    exit 1
  ''
)
