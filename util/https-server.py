#!/usr/bin/env python

import BaseHTTPServer, SimpleHTTPServer
import ssl
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--cert")
parser.add_argument("--key")
parser.add_argument("--cacert")

args = parser.parse_args()

print args

httpd = BaseHTTPServer.HTTPServer(('localhost', 4443), SimpleHTTPServer.SimpleHTTPRequestHandler)
httpd.socket = ssl.wrap_socket (httpd.socket, ca_certs=args.cacert, certfile=args.cert, keyfile=args.key,  cert_reqs=ssl.CERT_REQUIRED, server_side=True)
httpd.serve_forever()


