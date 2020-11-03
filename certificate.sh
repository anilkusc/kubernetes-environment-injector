#! /bin/sh
set -o errexit
yum install nano openssl -y
export APP="${1:-environment-injector}"
export NAMESPACE="${2:-default}"
export CSR_NAME="${APP}.${NAMESPACE}.svc"

echo "... creating ${app}.key"
openssl genrsa -out ${APP}.key 2048

echo "... creating ${app}.csr"
cat >csr.conf<<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${APP}
DNS.2 = ${APP}.${NAMESPACE}
DNS.3 = ${CSR_NAME}
DNS.4 = ${CSR_NAME}.cluster.local
EOF
echo "openssl req -new -key ${APP}.key -subj \"/CN=${CSR_NAME}\" -out ${APP}.csr -config csr.conf"
openssl req -new -key ${APP}.key -subj "/CN=${CSR_NAME}" -out ${APP}.csr -config csr.conf

echo "... deleting existing csr, if any"
echo "kubectl delete csr ${CSR_NAME} || :"
kubectl delete csr ${CSR_NAME} || :
	
echo "... creating kubernetes CSR object"
echo "kubectl create -f -"
kubectl create -f - <<EOF
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  groups:
  - system:authenticated
  request: $(cat ${APP}.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

SECONDS=0
while true; do
  echo "... waiting for csr to be present in kubernetes"
  echo "kubectl get csr ${CSR_NAME}"
  kubectl get csr ${CSR_NAME} > /dev/null 2>&1
  if [ "$?" -eq 0 ]; then
      break
  fi
  if [[ $SECONDS -ge 60 ]]; then
    echo "[!] timed out waiting for csr"
    exit 1
  fi
  sleep 2
done

kubectl certificate approve ${CSR_NAME}

SECONDS=0
while true; do
  echo "... waiting for serverCert to be present in kubernetes"
  echo "kubectl get csr ${CSR_NAME} -o jsonpath='{.status.certificate}'"
  serverCert=$(kubectl get csr ${CSR_NAME} -o jsonpath='{.status.certificate}')
  if [[ $serverCert != "" ]]; then 
    break
  fi
  if [[ $SECONDS -ge 60 ]]; then
    echo "[!] timed out waiting for serverCert"
    exit 1
  fi
  sleep 2
done

echo "... creating ${app}.pem cert file"
echo "\$serverCert | openssl base64 -d -A -out ${APP}.pem"
echo ${serverCert} | openssl base64 -d -A -out ${APP}.pem
caBundle=$( kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | sed 's/\\n//' )
#echo "-------------------------------------------------------------------------------"
#echo $caBundle
#echo "-------------------------------------------------------------------------------"
key=$(cat mutateme.key | sed 's/^/     /')
pem=$(cat mutateme.pem | sed 's/^/     /')
echo "
apiVersion: v1
kind: Service
metadata:
  name: environment-injector
  labels:
    app: environment-injector
spec:
  ports:
    - port: 443
      targetPort: 443
  selector:
    app: environment-injector   
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: environment-injector
  labels:
    app: environment-injector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: environment-injector
  template:
    metadata:
      name: environment-injector
      labels:
        app: environment-injector
    spec:
      containers:
      - name: environment-injector
        image: anilkuscu95/environment-injector              
        imagePullPolicy: Always
        ports:
          - containerPort: 443                
        volumeMounts:
        - name: key
          mountPath: /app/mutateme.key
          subPath: mutateme.key
        - name: pem
          mountPath: /app/mutateme.pem
          subPath: mutateme.pem
      volumes:
      - name: key
        configMap:
          name: key
      - name: pem
        configMap:
          name: pem
---
  kind: ConfigMap
  apiVersion: v1
  metadata:
    name: key
    labels:
      app: environment-injector
  data:
    mutateme.key: |-
$key
---
  kind: ConfigMap
  apiVersion: v1
  metadata:
    name: pem
    labels:
      app: environment-injector
  data:
    mutateme.pem: |-
$pem
---
apiVersion: admissionregistration.k8s.io/v1beta1
kind: MutatingWebhookConfiguration
metadata:
  name: environment-injector
  labels:
    app: environment-injector
webhooks:
  - name: environment-injector.default.svc.cluster.local
    clientConfig:
      caBundle: $caBundle
      service:
        name: environment-injector
        namespace: default
        path: '/mutate'
        port: 443
    rules:
      - operations: ['CREATE']
        apiGroups: ['']
        apiVersions: ['v1']
        resources: ['pods']
    sideEffects: None
    timeoutSeconds: 5
    reinvocationPolicy: Never
    failurePolicy: Ignore
    namespaceSelector:
      matchLabels:
        environment-injector: enabled
" > sample.yaml