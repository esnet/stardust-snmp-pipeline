#!/bin/bash

docker compose exec kafka bash /usr/lib/stardust/tests/bin/run_test_in_container.sh $*
