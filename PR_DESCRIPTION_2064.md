<!-- DRAFT for the developer to rewrite. Not a submission. -->

# Record insurance treatments on the bank statement

Fixes #2064.

## The problem

A patient treated through an insurance company watched a banknote float away and
saw nothing else happen. The money was banked against the company and reached the
hospital months later as one lump, so the day of treatment left no trace in the
statement at all.

That is correct behaviour — insurance pays late, and the bank manager graphs show
the delay. But from the statement it was indistinguishable from a patient who went
unpaid, which is exactly how the issue was reported: a $1120 operation on 9 Jan,
and an income column for 9–15 Jan listing only the cash payments.

## The fix

Log the treatment as its own entry at the moment the money is billed.

```
 4 Mar Insurance: Bloaty Head          $2000
```

The entry carries an `insurance` amount rather than `receive` or `spend`, so the
statement draws **neither** money column and the balance beside it is unchanged.
The hospital has earned the money and cannot spend it yet.

- `Hospital:addInsuranceMoney` takes a reason and logs the entry. `balance` and
  `money_in` are untouched; only the insurer's own balance changes, as before.
- `Hospital:receiveMoneyForTreatment` supplies the description.
- The statement renderer changes from `else` to `elseif values.receive`, so an
  entry with neither field leaves both money columns blank.

## Alternatives considered

**Log it as income immediately.** Cheapest, and needs no renderer change. Rejected
because it records money the hospital does not hold, which is the specific thing
`Alberth289346` objected to in the issue — the balance column would show a figure
that is not there.

**Add a running total owed to the bank manager page.** The page already draws
`bank_manager.insurance_owed` and the three insurer balances, so a single
outstanding total would slot in. Not done here: the per-treatment line answers the
question the issue was actually about, which is "what happened to this patient".

## The wording

The first version read `Cure: Bloaty Head - billed to insurance: Mutant United`.
It overflowed the details cell and ran off the screen, which the developer found by
playing the game. It now reads `Insurance: Bloaty Head`, reusing the original
game's `transactions.insurance_colon` — so **no new translation string is needed**
and every language already has it.

A cash treatment still reads `Cure: Bloaty Head`, so the distinguishing word is at
the front of the line.

## Trade-offs

- The insurer's name no longer appears on the line. A player wanting to know which
  company is owed has to use the bank manager page.
- Roughly a quarter of all treatments now add a statement line, against a 20-entry
  cap, so the statement fills faster than before.

## Tests

19 new tests in `hospital_spec.lua`:

- the insurer's month balance changes, and no other month slot does
- `balance` and `money_in` are unchanged
- the entry carries `insurance` and **neither** `receive` nor `spend`, which is
  what leaves the money columns empty
- the logged balance equals the pre-existing balance
- free build mode logs nothing but still banks the insurer's balance
- the description is exactly `Insurance: Bloaty Head` and at most 30 characters

The last two were added after the first round of tests passed against the long
wording unchanged — the tests called `addInsuranceMoney` directly, so nothing
covered the caller that builds the text. Reinstating the long wording now fails
two of them.

## Related

**#1375** (blue banknote for insurance) is separate and also open. It fixes the same
confusion at the moment of payment; this fixes it in the ledger afterwards.