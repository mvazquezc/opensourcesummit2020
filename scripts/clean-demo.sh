#!/bin/bash
rm -rf ~/reverse-words/
rm -rf ~/reverse-words-cicd/
rm -rf ~/tls-certs/
kind delete cluster --name demo-cluster
