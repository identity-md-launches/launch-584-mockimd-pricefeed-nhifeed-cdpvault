# CDPVault liquidation increment

This change adds the spot divergence bound, marker reward, simple stability fee and visible bad debt to `src/CDPVault.sol`. Feed implementations, the primary-price payout formula, NHI thresholds, snapshotted grace, liquidation window, feed deviation band, and both existing deployment hooks retain their behavior. No tokens, configuration, deployment scripts or manifest are changed.

## Constructor and integration

The first five constructor arguments keep their order. Append:

| Argument | Approved deployment value | Meaning |
| --- | --- | --- |
| `address spotFeed` | Separate deployed spot feed | Sanity bound on primary average price |
| `uint256 maxDivergenceBps` | `500` | Difference allowed as a share of the primary |
| `uint256 markerShareBps` | `1000` | Share of the existing liquidation bonus |
| `uint256 stabilityFeeBps` | `0` | Annual interest rate; this deployment ships inert |

Each basis-point argument is bounded by 10,000. Spot must have code and cannot be the NHI feed. Reusing the primary as spot remains possible for compatibility tests, but provides no independent bound and is not the approved deployment configuration. All parameters are immutable. No initializer, setter or new authority is added.

`positions(account)` retains its two outputs, but its debt output now includes current unpaid fees. `liquidationMarks(account)` appends `address marker` after `(markedAt, grace, marked)`. The complete export is [abi/CDPVault.json](abi/CDPVault.json).

`script/DeployComp.s.sol` now deploys a third `PriceFeed` with the same words as the primary as the spot feed and constructs the vault with `maxDivergenceBps` 500, `markerShareBps` 1000 and `stabilityFeeBps` 0; its `verify()` checks all four new immutables. `script/SeedAndSmoke.s.sol` seeds the spot feed too (`SPOT_PRICE`, defaulting to `PRICE`) because `mintCOMP` requires it fresh and in agreement. The inherited test fixtures pass the primary feed as spot with all three words zero, which is the compatibility configuration: nothing those tests assert depends on divergence, marker pay or fees, so their checks are unchanged. The focused suite under `docs/tests/` uses a separate spot feed and nonzero words. `launch.json` is the manifest assignment's and still carries the old five arguments; it must supply the new constructor words and a separate spot feed. The check runner below predates the fixture migration and remains usable: it leaves nine-argument calls alone.

## Price and marker behavior

`mintCOMP`, `markUnderwater`, `liquidate`, a debt-bearing `withdrawCollateral` and `clearRecoveredMark` retain their primary/NHI freshness checks and additionally require a fresh, nonzero spot with:

```text
abs(primary - spot) <= floor(primary * maxDivergenceBps / 10000)
```

The accepted boundary is inclusive. Health and payout always use the primary. Repayment and debt-free withdrawal do not consult the divergence bound. A withdrawal with open debt does: it is permitted only because the primary says the remainder is healthy, so a pushed primary that spot contradicts must not release collateral against debt (the revision finding reproduced this with a primary of 2 against a spot of 1 letting a position at the minimum CR withdraw half its collateral). Clearing a recovered mark is judged at the same price and is guarded for the same reason. Existing guards for work minting and deposits retain their scope. A pinned closing block and an attestation valid for its TTL expose both a known manipulation target and a later execution opportunity; the primary average is therefore the pricing input and spot is only a disagreement detector. This change does not implement averaging inside a feed.

An active mark preserves both its marker and grace snapshot. A cleared or expired mark can be replaced. On liquidation, compute the original collateral seizure and principal payout, then split only their difference:

```text
seized      = floor(repaid * 1.1e18 / primary)
principal   = floor(repaid * 1e18 / primary)
bonus       = seized - principal
markerCut   = floor(bonus * markerShareBps / 10000)
protocolCut = floor(bonus * protocolBonusShareBps() / 10000)
liquidator  = seized - markerCut - protocolCut
```

Combined bonus shares above 10,000 revert. The virtual protocol hook is unchanged. A marker who also liquidates receives one combined transfer. The marker is captured before recovery can delete the mark. The borrower loses exactly `seized` for every valid share configuration.

## Linear fee accounting

The global index is `1e18 + floor((now - deployedAt) * stabilityFeeBps * 1e18 / (365 days * 10000))`. Each debt change checkpoints its account's index. Interest is outstanding principal multiplied by the index delta, divided by `1e18`; unpaid interest never becomes interest-bearing principal. Fractional remainders survive partial repayment and additional borrowing, so repeated checkpoints cannot discard accrued fractions. Full repayment clears the remaining fraction below one token minor unit.

Every position debt view and health decision includes the live fee. Deposits, reads and marking do not reset the debt checkpoint. Repayment and liquidation pay fees first, burn the full COMP payment, and mint only the paid fee portion to the unchanged `FEE_RECIPIENT`. `feeOf` exposes unpaid fees; `totalFeesMinted` records cumulative paid fees. A failed token burn rolls back all accounting.

The original ceiling remains a limit on issued principal: `totalDebt` is the sum of borrowed principal, and only principal repayment frees headroom. Accrued interest may make the total owed exceed that issuance ceiling. This avoids silently changing the existing ceiling hook or admitting new principal because an interest payment was mistaken for principal repayment.

The workflow's requested additive supply formula does not hold for unminted interest. For example, after borrowing 100 COMP and accruing 10, supply remains 100 while the borrower owes 110. Burning a fee payment and minting it to the recipient preserves supply. The precise identity is stated once in `mintFromWork` NatSpec and asserted using independent principal/fee balances in the new tests. Adding cumulative fees minted again would double-count that payment. No extra unbacked COMP is minted to force the inconsistent formula to pass.

## Bad debt without forgiveness

`badDebtOf(account)` reports accrued debt beyond what the existing 110% payout can cover at the latest primary price. It accounts for floor rounding: the largest executable repayment is `ceil((collateral + 1) * price / 1.1e18) - 1`. Arithmetic is split to avoid overflowing `collateral + 1` or the intermediate product. With zero collateral the entire current debt is uncovered. This is a price view, not a freshness or liquidation-eligibility check.

The original `InsufficientCollateral` guard remains. A caller must choose a repayment whose full payout fits; the contract does not clamp a requested repayment, seize extra collateral dust, forgive a remainder, or add insurance.

`totalBadDebt` sums recognized outstanding records, not every account's live price shortfall. When liquidation exhausts collateral, the remaining accrued debt becomes `recordedBadDebtOf(account)`. While that record is nonzero, debt-changing calls add subsequent accrued fees and subtract actual payments. A collateral deposit or price recovery does not erase the record. If the account recapitalizes and borrows again, new principal is not automatically recognized, but subsequent fees still join its outstanding record until it is paid. This is deliberately conservative historical recognition; `badDebtOf` separately shows current coverage. Passage of time alone does not update the accumulator.

## Checks and review

Run the delivered focused suite offline, keeping artifacts inside the permitted scratch directory:

```sh
FOUNDRY_TEST=docs/tests FOUNDRY_SCRIPT=test/scratch/empty-script \
FOUNDRY_OUT=test/scratch/increment-out FOUNDRY_CACHE_PATH=test/scratch/increment-cache \
forge test --offline
```

Run the inherited suite with adapted constructor and mark outputs:

```sh
python3 docs/tests/run-vault-checks.py --offline
```

Observed results: 31 focused tests and 199 inherited tests passed. Focused coverage includes both divergence directions and exact bounds; stale/zero spot; repayment and exit liveness; marker replacement and combined transfers; payout conservation; late borrowing, simple interest, fractional carry, partial/full repayments and failure rollback; accrued-debt health and liquidation; ceiling behavior; executable shortfall rounding; and supply conservation fuzzing with 256 runs. Inherited checks cover the existing grace, deviation, ceiling and protocol-share behavior, token properties, runtime/opcode limits, fuzzing and invariant campaigns.

The unmodified InHouse fixture fails locally because it names a live Sepolia collateral address. The runner installs the existing MockIMD runtime at that address using a test cheatcode; its 14 checks then pass. Those results are local checks, not claims about live Sepolia state. No network dependency was added.

A separate review of the changed vault identified a concrete sequence where a dust deposit could stop recognized bad-debt fees from being checkpointed, then fee-first repayment could clear the record prematurely. The implementation now accrues into an outstanding record regardless of collateral, and the focused suite reproduces the sequence. The reviewer also compared the shortfall arithmetic with exact payout capacity over 200,000 randomized uint256 cases and found no mismatch. This review is not the independently assigned source-and-manifest launch review.

Existing deployment concerns remain outside this change: `FEE_RECIPIENT` is the same address as the approved reporter/relayer in the supplied configuration, so enabling revenue retains that incentive conflict. The approved stability rate remains zero, and the protocol bonus hook still defaults to zero. Legacy feed-attestation prose elsewhere in the repository may predate the current feed implementation; no feed logic or unrelated documentation was revised. Services remain responsible for the source/manifest linkage, attestation, admission and deployment.
