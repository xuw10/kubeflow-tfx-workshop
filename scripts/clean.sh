#!/bin/bash -e

kubectl delete workflow --all
kubectl delete tfjob --all
kubectl delete studyjob --all

