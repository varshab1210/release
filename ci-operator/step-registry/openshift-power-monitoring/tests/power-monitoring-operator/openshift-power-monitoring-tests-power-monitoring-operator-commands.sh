#!/bin/bash

set -eu -o pipefail

declare -r LOGS_DIR="/$ARTIFACT_DIR/test-run-logs"
declare -r OPERATOR_DEPLOY_NAME="kepler-operator-controller"
declare -r OPERATORS_NS="openshift-operators"
declare -r TEST_IMAGES_YAML="tests/images.yaml"

declare KEPLER_DEPLOYMENT_NS=""

validate_install() {
	echo "Validating Operator Install"

	oc rollout status -n "$OPERATORS_NS" "deployment/$OPERATOR_DEPLOY_NAME"
	oc wait --for condition=Available -n "$OPERATORS_NS" --timeout=300s deployment "$OPERATOR_DEPLOY_NAME"
	oc logs -n "$OPERATORS_NS" "deployment/$OPERATOR_DEPLOY_NAME"
}

must_gather() {
	echo "Running must gather"

	echo "Gather OLM resources"

	for x in $(oc api-resources --api-group=operators.coreos.com -o name); do
		oc get "$x" -n "$OPERATORS_NS" -o yaml | tee "$LOGS_DIR/$x.yaml"
	done
	oc get pods -n "$OPERATORS_NS" -o yaml | tee "$LOGS_DIR/pod.yaml"
	oc describe deployment "$OPERATOR_DEPLOY_NAME" -n "$OPERATORS_NS" | tee "$LOGS_DIR/$OPERATOR_DEPLOY_NAME"
	oc logs -n "$OPERATORS_NS" "deployment/$OPERATOR_DEPLOY_NAME" | tee "$LOGS_DIR/$OPERATOR_DEPLOY_NAME.log"
}

log_events() {
	local ns="$1"
	shift
	oc get events -w \
		-o custom-columns=FirstSeen:.firstTimestamp,LastSeen:.lastTimestamp,Count:.count,From:.source.component,Type:.type,Reason:.reason,Message:.message \
		-n "$ns" | tee "$LOGS_DIR/$ns-events.log"
}

validate_ds() {
	local ns="$1"
	local ds="$2"
	local -i max_tries="$3"
	local -i timeout="$4"
	shift 4
	local -i tries=0
	local -i ready=0
	local -i desired=0
	local -i ret=1
	while [[ $tries -lt $max_tries ]]; do
		ready=$(oc -n "$ns" get daemonset "$ds" -o jsonpath='{.status.numberReady}')
		desired=$(oc -n "$ns" get daemonset "$ds" -o jsonpath='{.status.desiredNumberScheduled}')
		[[ $ready -eq $desired ]] && {
			ret=0
			break
		}
		tries=$((tries + 1))
		echo "[$tries / $max_tries]: waiting ($timeout) for $ds to be ready"
		sleep "$timeout"
	done
	return $ret
}

create_ds() {
	# Note: This is needed to load the model server image to the OCP nodes
	# before the test runs since model server image is heavy in size and
	# requires time to pull from quay.io
	local img=""
	img=$(grep -i 'quay.io' $TEST_IMAGES_YAML | awk -F "'" '{print $2}')

	echo "creating dummy model-server daemonset inside default namespace using image: $img"
	oc apply -n default -f - <<EOF
  apiVersion: apps/v1
  kind: DaemonSet
  metadata:
    name: dummy-model-server
    labels:
      app: dummy-model-server
  spec:
    selector:
      matchLabels:
        name: dummy-model-server
    template:
      metadata:
        labels:
          name: dummy-model-server
      spec:
        tolerations:
          - key: node-role.kubernetes.io/master
            effect: "NoSchedule"
            operator: "Exists"
        containers:
        - name: model-server
          image: $img
          imagePullPolicy: Always
          command: ["python3.8","-u","src/server/model_server.py"]
EOF

	validate_ds default dummy-model-server 5 20 || {
		echo "daemonset not in ready state"
		oc get daemonset -n default -o yaml | tee "$LOGS_DIR/model-server-ds.yaml"
		return 1
	}
	oc delete -n default daemonset dummy-model-server # Deleting the daemonset to make sure it doesn't interfere with the test
	return 0
}

main() {
	mkdir -p "$LOGS_DIR"
	validate_install || {
		must_gather
		echo "Operator validation failed"
		return 1
	}

	create_ds || {
		echo "failed to create dummy model server daemonset"
		return 1
	}

	[[ -z "$KEPLER_DEPLOYMENT_NS" ]] && {
		KEPLER_DEPLOYMENT_NS=$(oc get "deployment/$OPERATOR_DEPLOY_NAME" -n "$OPERATORS_NS" \
			-o jsonpath='{.spec.template.spec.containers[*].args[*]}' | awk -F'--deployment-namespace=' '{print $2}' | awk '{print $1}')
	}

	echo "Running e2e tests"

	log_events "$OPERATORS_NS" &
	log_events "$KEPLER_DEPLOYMENT_NS" &

	local ret=0

	./e2e.test -test.v -test.failfast -deployment-namespace="$KEPLER_DEPLOYMENT_NS" 2>&1 | tee "$LOGS_DIR/e2e.log" || ret=1

	# terminating both log_events
	{ jobs -p | xargs -I {} -- pkill -TERM -P {}; } || true
	wait
	sleep 1

	[[ "$ret" -ne 0 ]] && {
		must_gather
		echo "e2e tests failed"
		return $ret
	}
	echo "e2e tests passed"
	return $ret
}
main "$@"
