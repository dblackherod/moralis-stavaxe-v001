# moralis-stavaxe-v001
Solidity contracts for [StAVAXe](https://szrpfqb4kst0.usemoralis.com) Moralis-Avalanche Hackathon 2021-22.
Currently deployed on Avalanche (Fuji) Testnet.

# About
Stake AVAX on Benqi LP and Earn Rewards

StAVAXe is a non-custodial yields earning decentralized app that lets Bitcoin/Ethereum holders earn [AVAX](https://www.avax.netwprk),
and [Qi](https://benqi.fi) rewards for holding [YAK](https://yieldyak.com) tokens.

Bitcoin (wBTC/wBTC.e) or Ethereum (wETH/wETH.e) is swapped to AVAX (wAVAX) for Yield-Yak Receipt Tokens (YRT), and staked in BenQi LP.
Interests earned on both assets are reinvested automatically into the LP, or swapped back to original assets with [YYSwap](https://yieldyak.com/swap). Token exchange prices are queried from YYSwap DEX aggregator.

# Implementaiton
StAVAXe provides custom Yield-Yak implementations for its vault and BTC strategy. See [Yield-Yak Smart Contracts](https://github.com/yieldyak/smart-contracts) repository for reference.

# Issues
Current deployment is on Moralis nginx server, which returns error page on successful network chain change. This is merely an issue with server.conf file setup which there is no known workaround for customizing Moralis server configuration. Navigate back to / to continue.
We are looking to move to production server within the coming months.

# Support
Fork, Feedback, Follow (on github)