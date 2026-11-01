---
id: srv0/base/app-egress
title: Egress policies
summary: "The default-deny posture and the explicit egress paths apps are allowed to use."
tags: [security]
---
`app-egress` is the network-policy baseline for the apps namespace: deny by default, then admit the specific DNS, NFS, gateway, and external paths each app needs. Component-specific policies add the pod-to-pod edges (database, cache, ML, MQTT).

If a new app needs a new destination, add a policy with the narrowest selector and port. This is why the app security card groups the NetworkPolicies.
