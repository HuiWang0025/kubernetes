#!/usr/bin/env bash

# Copyright 2020 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

run_exec_credentials_tests() {
  set -o nounset
  set -o errexit

  kube::log::status "Testing kubectl with configured exec credentials plugin"

  cat > "${TMPDIR:-/tmp}"/invalid_exec_plugin.yaml << EOF
apiVersion: v1
clusters:
- cluster:
  name: test
contexts:
- context:
    cluster: test
    user: invalid_token_user
  name: test
current-context: test
kind: Config
preferences: {}
users:
- name: invalid_token_user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      # Any invalid exec credential plugin will do to demonstrate
      command: ls
EOF

  ### Provided --token should take precedence, thus not triggering the (invalid) exec credential plugin
  # Pre-condition: Client certificate authentication enabled on the API server
  kube::util::test_client_certificate_authentication_enabled
  # Command
  output=$(kubectl "${kube_flags_with_token[@]:?}" --kubeconfig="${TMPDIR:-/tmp}"/invalid_exec_plugin.yaml get namespace kube-system -o name || true)

  if [[ "${output}" == "namespace/kube-system" ]]; then
    kube::log::status "exec credential plugin not triggered since kubectl was called with provided --token"
  else
    kube::log::status "Unexpected output when providing --token for authentication - exec credential plugin likely triggered. Output: ${output}"
    exit 1    
  fi
  # Post-condition: None

  ### Without provided --token, the exec credential plugin should be triggered
  # Pre-condition: Client certificate authentication enabled on the API server - already checked by positive test above

  # Command
  output2=$(kubectl "${kube_flags_without_token[@]:?}" --kubeconfig="${TMPDIR:-/tmp}"/invalid_exec_plugin.yaml get namespace kube-system -o name 2>&1 || true)

  if [[ "${output2}" =~ "json parse error" ]]; then
    kube::log::status "exec credential plugin triggered since kubectl was called without provided --token"
  else
    kube::log::status "Unexpected output when not providing --token for authentication - exec credential plugin not triggered. Output: ${output2}"
    exit 1
  fi
  # Post-condition: None

  cat > "${TMPDIR:-/tmp}"/valid_exec_plugin.yaml << EOF
apiVersion: v1
clusters:
- cluster:
  name: test
contexts:
- context:
    cluster: test
    user: valid_token_user
  name: test
current-context: test
kind: Config
preferences: {}
users:
- name: valid_token_user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: echo
      args:
        - '{"apiVersion":"client.authentication.k8s.io/v1beta1","status":{"token":"admin-token"}}'
EOF

  ### Valid exec plugin should authenticate user properly
  # Pre-condition: Client certificate authentication enabled on the API server - already checked by positive test above

  # Command
  output3=$(kubectl "${kube_flags_without_token[@]:?}" --kubeconfig="${TMPDIR:-/tmp}"/valid_exec_plugin.yaml get namespace kube-system -o name 2>&1 || true)

  if [[ "${output3}" == "namespace/kube-system" ]]; then
    kube::log::status "exec credential plugin triggered and provided valid credentials"
  else
    kube::log::status "Unexpected output when using valid exec credential plugin for authentication. Output: ${output3}"
    exit 1
  fi
  # Post-condition: None

  ### Provided --username/--password should take precedence, thus not triggering the (valid) exec credential plugin
  # Pre-condition: Client certificate authentication enabled on the API server - already checked by positive test above

  # Command
  output4=$(kubectl "${kube_flags_without_token[@]:?}" --username bad --password wrong --kubeconfig="${TMPDIR:-/tmp}"/valid_exec_plugin.yaml get namespace kube-system -o name 2>&1 || true)

  if [[ "${output4}" =~ "Unauthorized" ]]; then
    kube::log::status "exec credential plugin not triggered since kubectl was called with provided --username/--password"
  else
    kube::log::status "Unexpected output when providing --username/--password for authentication - exec credential plugin likely triggered. Output: ${output4}"
    exit 1
  fi
  # Post-condition: None

  rm "${TMPDIR:-/tmp}"/invalid_exec_plugin.yaml
  rm "${TMPDIR:-/tmp}"/valid_exec_plugin.yaml

  set +o nounset
  set +o errexit
}

run_exec_credentials_interactive_tests() {
  set -o nounset
  set -o errexit

  kube::log::status "Testing kubectl with configured interactive exec credentials plugin"

  cat > "${TMPDIR:-/tmp}"/always_interactive_exec_plugin.yaml << EOF
apiVersion: v1
clusters:
- cluster:
  name: test
contexts:
- context:
    cluster: test
    user: always_interactive_token_user
  name: test
current-context: test
kind: Config
preferences: {}
users:
- name: always_interactive_token_user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: echo
      args:
        - '{"apiVersion":"client.authentication.k8s.io/v1beta1","status":{"token":"admin-token"}}'
      interactiveMode: Always
EOF

  ### The exec credential plugin should not be run if it kubectl already uses standard input
  # Pre-condition: The kubectl command requires standard input

  some_resource='{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"some-resource"}}'

  # Declare map from kubectl command to standard input data
  declare -A kubectl_commands
  kubectl_commands["apply -f -"]="$some_resource"
  kubectl_commands["set env deployment/some-deployment -"]="SOME_ENV_VAR_KEY=SOME_ENV_VAR_VAL"
  kubectl_commands["replace -f - --force"]="$some_resource"

  failure=
  for kubectl_command in "${!kubectl_commands[@]}"; do
    # Use a separate bash script for the command here so that script(1) will not get confused with kubectl flags
    script_file="${TMPDIR:-/tmp}/test-cmd-exec-credentials-script-file.sh"
    cat <<EOF >"$script_file"
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
kubectl ${kube_flags_without_token[*]:?} --kubeconfig=${TMPDIR:-/tmp}/always_interactive_exec_plugin.yaml ${kubectl_command} 2>&1 || true
EOF
    chmod +x "$script_file"

    # Run kubectl as child of script(1) so kubectl will always run with a PTY
    # Dynamically build script(1) command so that we can conditionally add flags on Linux
    script_command="script -q /dev/null"
    if [[ "$(uname)" == "Linux" ]]; then script_command="${script_command} -c"; fi
    script_command="${script_command} ${script_file}"

    # Specify SHELL env var when we call script(1) since it is picky about the format of the env var
    shell="$(which bash)"

    kube::log::status "Running command '$script_command' (kubectl command: '$kubectl_command') with input '${kubectl_commands[$kubectl_command]}'"
    output=$(echo "${kubectl_commands[$kubectl_command]}" | SHELL="$shell" $script_command)

    if [[ "${output}" =~ "used by stdin resource manifest reader" ]]; then
      kube::log::status "exec credential plugin not run because kubectl already uses standard input"
    else
      kube::log::status "Unexpected output when running kubectl command that uses standard input. Output: ${output}"
      failure=yup
    fi
  done

  if [[ -n "$failure" ]]; then
    exit 1
  fi

  # Post-condition: None

  rm "${TMPDIR:-/tmp}"/always_interactive_exec_plugin.yaml

  set +o nounset
  set +o errexit
}