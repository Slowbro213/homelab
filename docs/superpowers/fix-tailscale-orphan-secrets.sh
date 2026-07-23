#!/usr/bin/env bash
#
# One-shot repair for the post-NixOS-migration tailscale operator breakage.
#
# Velero restored the OLD cluster's tailscale proxy Secrets alongside the ones the
# rebuilt operator created. provisionSecrets() in cmd/k8s-operator/sts.go lists every
# Secret with the ingress's child-resource labels and runs
#     fmt.Sscanf(secret.Name, hsvc.Name+"-%d", &ordinal)
# on each, so an orphan whose prefix doesn't match the current headless Service aborts
# the reconcile with Go's fmt error "input does not match format" -- before any
# StatefulSet is created.
#
# This re-keys each orphan onto the live Service name with ordinal -1. Sscanf then
# succeeds, ordinal(1) >= Replicas(1), and the operator's own scale-down path deletes
# the dead tailnet device and the Secret using its own credentials.
#
# Run against the control-plane node:
#   ssh slowking@cachyos 'DRY=1 bash -s' < docs/superpowers/fix-tailscale-orphan-secrets.sh   # preview
#   ssh slowking@cachyos 'DRY=0 bash -s' < docs/superpowers/fix-tailscale-orphan-secrets.sh   # apply
#
# Env: DRY=1 preview only (default). ONLY='ts-longhorn-*' restrict to one app.

set -eu
NS=tailscale
DRY=${DRY:-1}

for s in $(kubectl -n $NS get secrets -l tailscale.com/parent-resource-type=ingress -o name | sed 's|secret/||'); do
  base=${s%-*}
  # A Secret whose name-prefix is an existing headless Service is the live one -- leave it.
  if kubectl -n $NS get svc "$base" >/dev/null 2>&1; then
    continue
  fi
  case "$s" in ${ONLY:-*}) ;; *) continue ;; esac

  parent=$(kubectl -n $NS get secret "$s" -o jsonpath='{.metadata.labels.tailscale\.com/parent-resource}')
  live=$(kubectl -n $NS get svc -l "tailscale.com/parent-resource=$parent" -o name | sed 's|service/||')
  if [ -z "$live" ] || [ "$(echo "$live" | wc -l)" -ne 1 ]; then
    echo "!! $s: no unique live Service for parent=$parent (got: $live) -- skipping" >&2
    continue
  fi
  new="${live}-1"
  did=$(kubectl -n $NS get secret "$s" -o jsonpath='{.data.device_id}' | base64 -d)
  echo "$s  ->  $new   (operator will delete dead device $did)"
  [ "$DRY" = "1" ] && continue

  kubectl -n $NS get secret "$s" -o json \
    | jq --arg n "$new" '.metadata.name=$n
        | del(.metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid,
              .metadata.ownerReferences, .metadata.managedFields, .metadata.selfLink,
              .metadata.generation, .metadata.annotations)' \
    | kubectl apply -f -
  kubectl -n $NS delete secret "$s"
done
