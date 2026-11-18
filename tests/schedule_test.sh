#!/usr/bin/env bash
# Compiles BuildSchedule from the simulator source against small stubs (no ns-3 needed)
# and checks its invariants. Run from the repository root: tests/schedule_test.sh
set -euo pipefail
SRC=scratch/iiot-consensus-tsn.cc; T=$(mktemp -d)
python3 - "$SRC" "$T/sched.inc" <<'PY'
import sys
s=open(sys.argv[1]).read(); a=s.index('using GateWindow =')
i=s.index('OpenClassOf(const NetDeviceListConfig::GateStateMap& g)'); b=s.index('\n}\n',i)+3
open(sys.argv[2],'w').write(s[a:b])
PY
cat > "$T/t.cc" <<'CC'
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <utility>
#include <vector>
struct Time { int64_t ns{0}; Time()=default; explicit Time(int64_t n):ns(n){} int64_t GetNanoSeconds() const {return ns;} };
struct NetDeviceListConfig { typedef std::array<bool,8> GateStateMap; };
#define NS_ABORT_MSG_IF(c,m) do{ if(c){ std::cerr<<"ABORT "<<m<<"\n"; std::exit(1);} }while(0)
static const uint32_t CLASS_CONTROL=6, CLASS_CONSENSUS=4, CLASS_BE=1;
#include "sched.inc"
using W=std::vector<std::pair<int64_t,int>>;
static W flat(const std::vector<GateWindow>& w){ W o; for(auto&x:w) o.push_back({x.first,OpenClassOf(x.second)}); return o; }
static int StateAt(const W& w,int64_t t,int64_t C){ t%=C; if(t<0)t+=C; int64_t a=0; for(auto&x:w){ if(t<a+x.first) return x.second; a+=x.first;} return -9; }
int main(){
  const int64_t C=1000000; int bad=0,n=0;
  for(double cf:{0.005,0.16,0.2}) for(double kf:{0.3,0.6,0.832}) { if(cf+kf>1.0) continue;
    for(unsigned K:{1u,2u,3u,4u,5u,7u,8u,12u,16u}) {
      W nom=flat(BuildSchedule(Time(C),cf,kf,Time(0),K));
      int64_t sum=0,tc=0,tk=0,tb=0; int nk=0; for(auto&x:nom){ sum+=x.first; if(x.second==6)tc+=x.first; if(x.second==4){tk+=x.first;++nk;} if(x.second==1)tb+=x.first; }
      bool ok = sum==C && tc==(int64_t)(C*cf) && tk==(int64_t)(C*kf) && tb==C-tc-tk && nk==(int)K;
      if(K==1){ ok = ok && nom.size()==3 && nom[0].second==6 && nom[1].second==4 && nom[2].second==1; }   // [ctrl][cons][be]
      for(int64_t ph:{852L,7620L,13*852L,123457L,999999L}){
        W sh=flat(BuildSchedule(Time(C),cf,kf,Time(ph),K)); int64_t s2=0; for(auto&x:sh) s2+=x.first; if(s2!=C) ok=false;
        for(int64_t t=0;t<C;t+=1013){ int64_t ref=((t-ph)%C+C)%C; if(StateAt(sh,t,C)!=StateAt(nom,ref,C)){ok=false;break;} } }
      ++n; if(!ok){ ++bad; std::printf("FAIL cf=%g kf=%g K=%u\n",cf,kf,K);} } }
  std::printf("schedule invariants: %d/%d configurations pass\n",n-bad,n); return bad?1:0; }
CC
g++ -std=c++17 -Wall -o "$T/t" "$T/t.cc" -Wno-unused-function && "$T/t"
