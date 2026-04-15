#!/usr/bin/env bash
# À exécuter sur le cluster PRINCIPAL après création de l'instance Argo CD.
# Autorise les Application dans managed-cluster et gitops-control-plane (Apps in any namespace).
set -euo pipefail
NS="${1:-gitops-control-plane}"

oc patch appproject default -n "${NS}" --type=merge -p '{
  "spec": {
    "sourceNamespaces": ["managed-cluster","gitops-control-plane"]
  }
}'
