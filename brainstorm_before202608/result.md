# RTCP Feedback Experiment Result

## Final Status

I completed a sender-side RTCP-like feedback comparison with real Joule readings on `myserver`.

The final measured path was:

- sender: `myserver`
- sender source IP: `143.89.79.104`
- sender interface: `enp4s0`
- receiver target host: `huam@eez222.ece.ust.hk`
- receiver target IP: `143.89.46.222`

Important caveat:

- ICMP from `myserver` to `eez222` works.
- RTCP-like UDP packets from `myserver` to `eez222` did **not** reach the receiver application in my test.
- So the **Joule numbers below are sender-side measurements** of packet generation and transmission attempts.
- They are still useful for comparing `immediate` vs `grouped`, but they are not a full end-to-end receiver-validated RTC run.

## Experiment Setup

- `30 fps`
- `100 packets/frame`
- `30 s` per run
- `3 repeats` per mode
- feedback entry size: `12 B`
- immediate mode pacing: `spread`

Compared modes:

1. `immediate`: one feedback send per packet
2. `grouped`: one feedback send per frame, carrying 100 feedback entries

Packet sizing:

- immediate packet size: `24 B`
- grouped packet size: `1212 B`
- `1212 B < 1472 B`, so grouped mode should not be paying a UDP fragmentation penalty here

## Main Result

Grouped feedback is dramatically cheaper than immediate feedback on the sender side.

Average over 3 runs:

| Metric | Immediate | Grouped | Grouped vs Immediate |
|---|---:|---:|---:|
| Send calls | 90,000 | 900 | `-99.0%` |
| Sender payload bytes | 2,160,000 | 1,090,800 | `-49.5%` |
| NIC tx bytes | 5,946,161 | 1,132,965 | `-80.9%` |
| Total energy (J) | 1048.823 | 28.904 | `-97.2%` |
| Total power (W) | 34.961 | 0.963 | `-97.2%` |
| CPU avg (%) | 3.598 | 0.204 | `-94.3%` |
| CPU max (%) | 4.286 | 1.539 | `-64.1%` |
| User CPU time (s) | 19.042 | 0.721 | `-96.2%` |
| Sys CPU time (s) | 10.969 | 0.362 | `-96.7%` |
| Voluntary ctx switches | 2,568 | 1,254 | `-51.2%` |
| Involuntary ctx switches | 133.3 | 14.0 | `-89.5%` |

The ratio is very large:

- total energy: immediate is about `36.3x` grouped
- CPU average: immediate is about `17.6x` grouped
- user CPU time: immediate is about `26.4x` grouped
- sys CPU time: immediate is about `30.3x` grouped

## Energy Interpretation

The strongest energy result is the **total package energy**:

- immediate average: `1048.823 J`
- grouped average: `28.904 J`

I also computed `sender_only_energy_j = total_energy - idle_power * duration`, but grouped mode is so close to idle that baseline subtraction becomes noisy:

- grouped sender-only energy came out near zero, and one run was negative
- that does **not** mean grouped is physically generating negative energy
- it means grouped is close enough to idle that the idle-baseline estimate is noisier than the extra work

So the reliable interpretation is:

- immediate mode clearly burns substantial extra package energy
- grouped mode is close to the sender's idle floor in this setup
- for grouped mode, `total_energy_j` is more trustworthy than `sender_only_energy_j`

## Per-Run Joule Data

| Run | Mode | Duration (s) | Total Energy (J) | Idle Power (W) | Sender-only Energy (J) | NIC tx bytes | CPU avg (%) | User CPU (s) | Sys CPU (s) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | immediate | 30.000002 | 1059.270 | 1.080 | 1026.864 | 5,948,663 | 3.613 | 18.544 | 11.466 |
| 2 | immediate | 30.000002 | 1037.936 | 1.147 | 1003.513 | 5,942,904 | 3.590 | 19.791 | 10.221 |
| 3 | immediate | 30.000002 | 1049.264 | 1.017 | 1018.758 | 5,946,915 | 3.592 | 18.791 | 11.219 |
| 1 | grouped | 30.000062 | 28.159 | 0.942 | -0.100 | 1,132,805 | 0.196 | 0.791 | 0.290 |
| 2 | grouped | 30.000072 | 28.116 | 1.178 | -7.221 | 1,134,585 | 0.207 | 0.687 | 0.396 |
| 3 | grouped | 30.000060 | 30.436 | 0.968 | 1.408 | 1,131,504 | 0.208 | 0.685 | 0.400 |

## UDP Reachability Result

I also ran a bounded receiver validation on `eez222`:

- receiver bind: `0.0.0.0:5007`
- sender target: `143.89.46.222:5007`
- sender actually transmitted on `enp4s0`
- receiver summary still reported:
  - `started_receiving = false`
  - `total_packets = 0`

So in the current environment:

- `myserver -> eez222` ICMP is reachable
- `myserver -> eez222` UDP to the tested ports was **not** observed by the receiver process

That means this is not yet a true receiver-validated RTCP experiment.

## What We Can Conclude

Even without receiver-side validation, the sender-side conclusion is strong:

- per-packet feedback is much more expensive than grouped-per-frame feedback
- the major reason is not just payload size
- the dominant cost is the `90,000` vs `900` send-call difference and the corresponding scheduling/syscall overhead

This directly supports your original concern that:

- process switching matters
- send startup overhead matters
- CPU utilization differs substantially between the two strategies

## Recommended Next Step

To finish the exact experiment you originally wanted, the next best step is:

1. find a receiver host that both accepts inbound UDP from `myserver` and can run the receiver script
2. rerun the same sender with real receiver-side packet counts
3. optionally repeat once more on `wlo1` if you specifically need the WiFi sender path instead of the current `enp4s0` LAN path

## Files

- Report: [result.md](/Users/menghua/Research/soco_motivation/result.md:1)
- Sender script: [rtcp_feedback_sender.py](/Users/menghua/Research/soco_motivation/rtcp_feedback_sender.py:1)
- Receiver script: [rtcp_feedback_receiver.py](/Users/menghua/Research/soco_motivation/rtcp_feedback_receiver.py:1)
- Joule JSON results: [rtcp_feedback_results_joule](/Users/menghua/Research/soco_motivation/rtcp_feedback_results_joule)
- Earlier proxy-only results: [rtcp_feedback_results](/Users/menghua/Research/soco_motivation/rtcp_feedback_results)
