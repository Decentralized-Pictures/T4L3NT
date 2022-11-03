#!/bin/bash

usage () {
    cat >&2 <<!EOF
usage:
  $0 [<branch>]
!EOF
}

if [ $# -eq 1 ];
then
  BRANCH=$1
elif [ $# -eq 0 ]
then
  BRANCH="latest-release"
else
  usage
  exit 1
fi

set -e
set -x

# Non-python-related setup, to make this script read more like the
# installation from the point of view of a non-root user using sudo.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install sudo --yes
echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >> /etc/sudoers

##
## Install pyenv
##
## References:
##  - https://github.com/pyenv/pyenv/wiki#suggested-build-environment
##  - https://github.com/pyenv/pyenv-installer
##  - https://github.com/pyenv/pyenv/#set-up-your-shell-environment-for-pyenv

# [install pyenv system dependencies]
sudo apt-get install curl git --yes

# [install python build dependencies]
sudo apt-get install make build-essential libssl-dev zlib1g-dev \
    libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev --yes

# [install pyenv]
curl https://pyenv.run | bash

# [setup shell for pyenv]
export PATH="$HOME/.pyenv/bin:$PATH" # add pyenv to path
eval "$(pyenv init --path)" # adds pyenv plugins to path
eval "$(pyenv init -)" # adds pyenv setup to environment
eval "$(pyenv virtualenv-init -)" # adds virtualenv setup to environment

# [print pyenv version]
pyenv --version

# [verify pyenv installation]

# Check that the pyenv hook is installed:
[ -n "$PYENV_SHELL" ]

# Check that the pyenv virtualenv hook is installed:
[ "$PYENV_VIRTUALENV_INIT" = "1" ]

##
## Install python 3.10.5 through pyenv
##
## References:
##  - https://github.com/pyenv/pyenv#usage

# [install python through pyenv]
pyenv install 3.10.5
pyenv global 3.10.5

# [print python version]
python --version # should output 3.10.5

# [verify python version]
[ "$(python --version)" = "Python 3.10.5" ]

##
## Install poetry
##
## References:
##  - https://python-poetry.org/docs/master/#installing-with-the-official-installer

# [install poetry]
curl -sSL https://install.python-poetry.org -o install-poetry.py
python install-poetry.py --version 1.1.13 --yes

# [setup shell for poetry]
export PATH=$PATH:$HOME/.local/bin

# [print poetry version]
poetry --version # should output 1.1.13

# [verify poetry version]
[ "$(poetry --version)" = "Poetry version 1.1.13" ]

##
## Test installing Octez python development dependencies
##
git clone "$CI_REPOSITORY_URL" --depth 1 --branch "$BRANCH"

# [install octez python dev-dependencies]
cd tezos
poetry install

# [print pytest/sphinx-build versions]
poetry run pytest --version --version # should output python 6.2.5 and pytest-regtest-1.4.4+nomadiclabs
poetry run sphinx-build --version # should output 4.2.0

# [verify pytest/sphinx-build version]
[ "$(poetry run pytest --version 2>&1)" = "pytest 6.2.5" ]
[ "$(poetry run pip show pytest-regtest --version | grep Version | cut -d' ' -f2)" = "1.4.4+nomadiclabs" ]
[ "$(poetry run sphinx-build --version)" = "sphinx-build 4.2.0" ]
