# T4L3NT a Tezos Fork Arts & Culture focused blockchain

## Introduction

T4L3NT is a distributed consensus platform with meta-consensus
capability. T4L3NT not only comes to consensus about the state of its ledger,
like Bitcoin or Ethereum. It also comes to consensus about how the
protocol and the nodes should adapt and upgrade. For more information about
the project, see https://t4l3nt.net.

## Getting started

Instructions to install 
Downlaod the latest build or clone the repo

Docker
After downloading run the docker iamge <here>:

bunzip2 tlnt-chain.tar.bz2

Load the docker image:

docker load -i ./tlnt-chain.tar

docker run -it -p 8733:8733 -p 9733:9733  -v tlnt-data:/home/tlnt tlnt-chain:prod

docker exec -it <imagename> bash

Generate a wallet:

tlnt-client get keys <keyname>

Register as delegate to start staking

tlnt-client register key <keyname> as baker

Block explorer: explorer.tlnt.net

The source code of T4L3NT and Tezos is placed under the [MIT Open Source
License](https://opensource.org/licenses/MIT).

### Development workflow

We are a small team and intend to follow the updates to Tezos mainnet. Node operators can choose to vote for upgrades.

## Community

Links to community websites are gathered in the following community portals:
- Discord https://discord.gg/FBKpZQNeAc
- Reddit https://www.reddit.com/r/decentralizedpictures/
- Decentralized Pictures Financing App https://app.decentralized.pictures
