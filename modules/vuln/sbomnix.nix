# sbomnix whose vulnxscan has `--alpine`: a second grype pass against Alpine's security database.
# Carried here until sbomnix has it; vuln and the self-test both run this build.
tools: tools.sbomnix.overrideAttrs (old: {patches = (old.patches or []) ++ [./vulnxscan-alpine.patch];})
