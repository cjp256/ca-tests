#!/bin/bash

set -e

BASE_CA_NAME="mytestCA"
CA_ROOT_NAME=${BASE_CA_NAME}-root
CA_INT_NAME=${BASE_CA_NAME}-int
TEST_CERTS_DIR=${BASE_CA_NAME}-testcerts

rm -rf $CA_ROOT_NAME
rm -rf $CA_INT_NAME

mkdir -p $CA_ROOT_NAME

# create root CA

mkdir -p $CA_ROOT_NAME
pushd $CA_ROOT_NAME >/dev/null

    mkdir -p certs crl newcerts private
    chmod 700 private
    touch index.txt
    echo 1000 > serial
    cp ../conf/root-openssl.cnf openssl.cnf

    # generate self signed root CA cert
    openssl genrsa -out private/cakey.pem 2048 >/dev/null 2>&1
    openssl req -x509 -new -nodes -sha256 -key private/cakey.pem -out cacert.pem -subj "/C=US/ST=NY/L=ROME/O=ROOTCA/OU=ROOTCA/CN=ROOTCA" -days 365  >/dev/null 2>&1

popd >/dev/null

# create intermediate CA
mkdir -p $CA_INT_NAME
pushd $CA_INT_NAME >/dev/null

    mkdir -p certs crl newcerts private
    chmod 700 private
    touch index.txt
    echo 1000 > serial
    cp ../conf/int-openssl.cnf openssl.cnf

    # generate key and CSR for root CA to sign
    openssl genrsa -out private/cakey.pem 2048 >/dev/null 2>&1
    openssl req -config openssl.cnf -sha256 -new -key private/cakey.pem -out cacsr.pem -subj "/C=US/ST=NY/L=ROME/O=ROOTCA/OU=$CA_INT_NAME/CN=$CA_INT_NAME" -days 9999 >/dev/null 2>&1

popd >/dev/null

# sign intermediate CA CSR with root CA
pushd $CA_ROOT_NAME >/dev/null

    openssl ca -config openssl.cnf -keyfile private/cakey.pem -cert cacert.pem -extensions v3_ca -notext -md sha256 -in ../$CA_INT_NAME/cacsr.pem -out ../$CA_INT_NAME/cacert.pem -batch -days 9999 >/dev/null 2>&1

popd >/dev/null

# verify new intermediate CA cert
openssl verify -CAfile $CA_ROOT_NAME/cacert.pem $CA_INT_NAME/cacert.pem >/dev/null 2>&1

# create test client and server keys and CSRs
mkdir -p $TEST_CERTS_DIR
openssl genrsa -out $TEST_CERTS_DIR/testserver-$CA_INT_NAME-key.pem 2048 >/dev/null 2>&1
openssl req -sha256 -new -key $TEST_CERTS_DIR/testserver-$CA_INT_NAME-key.pem -out $TEST_CERTS_DIR/testserver-$CA_INT_NAME-csr.pem -subj "/C=US/ST=NY/L=ROME/O=ROOTCA/OU=TESTSERVER$CA_INT_NAME/CN=localhost" >/dev/null 2>&1

openssl genrsa -out $TEST_CERTS_DIR/testclient-$CA_INT_NAME-key.pem 2048 >/dev/null 2>&1
openssl req -sha256 -new -key $TEST_CERTS_DIR/testclient-$CA_INT_NAME-key.pem -out $TEST_CERTS_DIR/testclient-$CA_INT_NAME-csr.pem -subj "/C=US/ST=NY/L=ROME/O=ROOTCA/OU=TESTCLIENT$CA_INT_NAME/CN=testclient-$CA_INT_NAME" >/dev/null 2>&1

# sign test client and server certs
pushd $CA_INT_NAME >/dev/null 2>&1

    openssl ca -config openssl.cnf -keyfile private/cakey.pem -cert cacert.pem -notext -md sha256 -in ../$TEST_CERTS_DIR/testclient-$CA_INT_NAME-csr.pem -out ../$TEST_CERTS_DIR/testclient-$CA_INT_NAME-cert.pem -batch -days 99999 >/dev/null 2>&1
    openssl ca -config openssl.cnf -keyfile private/cakey.pem -cert cacert.pem -notext -md sha256 -in ../$TEST_CERTS_DIR/testserver-$CA_INT_NAME-csr.pem -out ../$TEST_CERTS_DIR/testserver-$CA_INT_NAME-cert.pem -batch -days 99999 >/dev/null 2>&1

popd >/dev/null 2>&1

# build CA chain
cat $CA_INT_NAME/cacert.pem $CA_ROOT_NAME/cacert.pem > $CA_INT_NAME/cachain.pem

# verify client and server cert
openssl verify -CAfile $CA_INT_NAME/cachain.pem $TEST_CERTS_DIR/testserver-$CA_INT_NAME-cert.pem >/dev/null 2>&1
openssl verify -CAfile $CA_INT_NAME/cachain.pem $TEST_CERTS_DIR/testclient-$CA_INT_NAME-cert.pem >/dev/null 2>&1

# check if server is currently running - if so, kill it
for p in $(sudo lsof -i:4443 -t); do
    echo "kill running pid = $p"
    kill -9 $p
    sleep 1
done

# startup web server for testing
./util/https-server.py --cert $TEST_CERTS_DIR/testserver-$CA_INT_NAME-cert.pem --key $TEST_CERTS_DIR/testserver-$CA_INT_NAME-key.pem --cacert $CA_INT_NAME/cachain.pem >/dev/null 2>&1 &

HTTPS_PID=$!

sleep 2

# validate against ca chained certs
curl https://localhost:4443/ --cacert $CA_INT_NAME/cachain.pem --cert $TEST_CERTS_DIR/testclient-$CA_INT_NAME-cert.pem --key $TEST_CERTS_DIR/testclient-$CA_INT_NAME-key.pem >/dev/null 2>&1 && echo "curl validate against cachain: passed"

echo "" | openssl s_client -connect localhost:4443 -CAfile $CA_INT_NAME/cachain.pem -cert $TEST_CERTS_DIR/testclient-$CA_INT_NAME-cert.pem -key $TEST_CERTS_DIR/testclient-$CA_INT_NAME-key.pem 2>&1 | grep "Verify return code: 0 (ok)" >/dev/null && echo "openssl s_client validate against cachain: passed"

sleep 2

# validate against root CA cert
curl https://localhost:4443/ --cacert $CA_ROOT_NAME/cacert.pem --cert $TEST_CERTS_DIR/testclient-$CA_INT_NAME-cert.pem --key $TEST_CERTS_DIR/testclient-$CA_INT_NAME-key.pem >/dev/null 2>&1 && echo "curl validate against root cacert: passed"

sleep 2

# validate against just intermediate CA certificate (should fail)
curl https://localhost:4443/ --cacert $CA_INT_NAME/cacert.pem --cert $TEST_CERTS_DIR/testclient-$CA_INT_NAME-cert.pem --key $TEST_CERTS_DIR/testclient-$CA_INT_NAME-key.pem >/dev/null 2>&1 || echo "curl validate against intermediate cacert: passed (by failing)"

sleep 2

# validate against just intermediate CA certificate (should fail with "Verify return code: 19 (self signed certificate in certificate chain)")
echo "" | openssl s_client -connect localhost:4443 -CAfile $CA_INT_NAME/cacert.pem -cert $TEST_CERTS_DIR/testclient-$CA_INT_NAME-cert.pem -key $TEST_CERTS_DIR/testclient-$CA_INT_NAME-key.pem 2>&1 | grep "Verify return code: 19 (self signed certificate in certificate chain)" >/dev/null && echo "openssl s_client validate against intermediate cacert: passed (by failing)"

sleep 2

kill -9 $HTTPS_PID

