# SLA 探测 b2sla / 64k

SLA: TTFT < 20.0s 且 TPOT < 60.0ms

| 并发 | TPS | TTFT med | TPOT med | SLA |
|---|---|---|---|---|
| 4 | 46.51 | 9630.78 | 63.2 | FAIL:TPOT |
| 5 | 46.6 | 10479.24 | 69.02 | FAIL:TPOT |
| 6 | 46.67 | 13248.71 | 68.93 | FAIL:TPOT |

SLA 最大并发 = 0
