#!/bin/bash
# Submit standard-json verification for every deployed contract to the chain's
# Blockscout instance. The same bundles are already on Sourcify.
# Usage: ./submit.sh   (from the repo root or from verify/)
set -u
cd "$(dirname "$0")"
API="https://robinhoodchain.blockscout.com/api/v2/smart-contracts"
V26="v0.8.26+commit.8a97fa7a"

submit () { # addr file args
  local addr=$1 file=$2 args=$3
  echo "== $file -> $addr"
  curl -sS -X POST "$API/$addr/verification/via/standard-input" \
    -F "compiler_version=$V26" -F "license_type=mit" \
    -F "constructor_args=$(tr -d '\n' < "$args")" -F "autodetect_constructor_args=false" \
    -F "files[0]=@$file;type=application/json" | head -c 200
  echo; sleep 20
}

submit 0xbD86E40099E38B4081eDC3CBf56ED201Cd533A9F FeeshToken.json   args_FeeshToken.txt  # no constructor args
submit 0x7EA5866E3642A0835194aC083ba77b5E57f66793 FeeshSeeder.json  args_FeeshSeeder.txt
submit 0xcB44F2b726cB01f952691f4F81051190E2C51207 FeeshPond.json    args_FeeshPond.txt
submit 0x3d1F46aA87bbCdEcB3afb64Db6a84EAce32204cC FeeshFeeHook.json args_FeeshFeeHook.txt
submit 0x6D7f16f7003783aE71562E7e257103e2c7Cff21e FeeshRouter.json  args_FeeshRouter.txt

echo "--- status ---"
sleep 40
for a in 0xbD86E40099E38B4081eDC3CBf56ED201Cd533A9F 0x7EA5866E3642A0835194aC083ba77b5E57f66793 \
         0xcB44F2b726cB01f952691f4F81051190E2C51207 0x3d1F46aA87bbCdEcB3afb64Db6a84EAce32204cC \
         0x6D7f16f7003783aE71562E7e257103e2c7Cff21e; do
  echo "$a: $(curl -sS "$API/$a" | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); print(d.get('name'), 'verified' if d.get('source_code') else 'NOT verified')
except Exception: print('unreadable')")"
done
