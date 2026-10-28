#!/usr/bin/env bash
set -e

mkdir -p ebin
echo "Compiling Erlang modules..."
erlc -o ebin src/*.erl
cp src/load_balancer.app.src ebin/load_balancer.app

echo "Starting Erlang Load Balancer..."
echo "Listening on: http://localhost:8080"
echo "Rate limit: 10 requests / minute"

erl -pa ebin -config config/sys -s lb_app start

