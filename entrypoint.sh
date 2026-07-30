#!/bin/bash
echo "HELLO from entrypoint" >> /workspace/debug.log
echo "PATH=$PATH" >> /workspace/debug.log
echo "conda: $(which conda 2>&1)" >> /workspace/debug.log
echo "ns-process-data: $(which ns-process-data 2>&1)" >> /workspace/debug.log
echo "python: $(which python 2>&1)" >> /workspace/debug.log
cat /workspace/debug.log
sleep 3600
