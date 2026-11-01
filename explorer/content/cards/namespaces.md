---
id: srv0/base/namespaces
title: Namespaces & policy baseline
summary: "The base/apps split and the cluster-wide policies that every workload inherits."
tags: [security, cluster]
---
The chart creates `base` and `apps` and installs the baseline NetworkPolicies. The kube-system policy admits Traefik's host ports; the app baseline denies everything else until a component opts in.

Keeping the namespaces and baselines in the same file makes the default posture reviewable in one place.
