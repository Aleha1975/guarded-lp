import json,urllib.request,sys,time
CH="base"; API="https://aggregator-api.kyberswap.com/%s/api/v1"%CH
USDC="0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"; WETH="0x4200000000000000000000000000000000000006"
GATE="0x1111111111111111111111111111111111111111"
H={"x-client-id":"guarded-lp-test","Content-Type":"application/json","User-Agent":"Mozilla/5.0"}
def q(url,data=None):
    r=urllib.request.Request(url,data=json.dumps(data).encode() if data else None,headers=H)
    return json.load(urllib.request.urlopen(r,timeout=30))
def route(tin,tout,amt):
    rs=q(API+"/routes?tokenIn=%s&tokenOut=%s&amountIn=%s"%(tin,tout,amt))["data"]["routeSummary"]
    b=q(API+"/route/build",{"routeSummary":rs,"sender":GATE,"recipient":GATE,"slippageTolerance":300,"source":"guarded-lp-test"})["data"]
    return {"amountIn":str(amt),"amountOut":b["amountOut"],"data":b["data"],"routerAddress":b["routerAddress"]}
blk=int(json.load(urllib.request.urlopen(urllib.request.Request("https://lb.drpc.live/base/Ajgp-qfI9k_BkDuqr3dJ6FKJueTtzHwR8ajSAsHpgewq",data=b'{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}',headers={"Content-Type":"application/json"}),timeout=20))["result"],16)
fx={"block":blk,"buy":route(USDC,WETH,100_000_000),"sell":route(WETH,USDC,10**16)}
json.dump(fx,open("test/fixtures/base_kyber.json","w"),indent=1)
print("block",blk,"buy out",fx["buy"]["amountOut"],"sell out",fx["sell"]["amountOut"],"router",fx["buy"]["routerAddress"],"len",len(fx["buy"]["data"]))
