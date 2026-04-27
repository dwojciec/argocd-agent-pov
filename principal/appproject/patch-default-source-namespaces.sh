#!/usr/bin/env bash
# À exécuter sur le cluster PRINCIPAL après création de l'instance Argo CD.
# Autorise les Application dans managed-cluster et openshift-gitops (Apps in any namespace).
set -euo pipefail
NS="${1:-openshift-gitops}"

oc patch appproject default -n "${NS}" --type=merge -p '{
  "spec": {
    "sourceNamespaces": ["managed-cluster","openshift-gitops"]
  }
}'
