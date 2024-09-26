# helm-tester
simple script to test helm using kind. The script does the following:

1. installs kind
2. installs helm
3. installs kubectl
4. creates a kind clusters
5. deployes charts
6. test if they were deployed correctly (no pod in a bad state)

## how to use
```
./helm-tester.sh  "<dir to chart>;<dir to another chart>;<etc>;<etc>"
```
