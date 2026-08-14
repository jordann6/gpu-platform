## What changed

<!-- One or two sentences. What does this do, not how. -->

## Why

<!-- Link the issue or ADR. If this is an architectural choice, it needs an ADR
     in docs/adr/ before merge, not after. -->

## Author checklist

- [ ] I read the full `terraform plan` output, including every `must be replaced` reason
- [ ] No resource holding data is being destroyed or replaced (or the `destroy-approved` label is applied and the reason is stated below)
- [ ] I can explain what every line of this diff does without looking it up
- [ ] Cost impact is understood (check the Infracost comment; note anything recurring below)
- [ ] No credentials, account IDs, or customer data in the diff or in the commit history
- [ ] Provider and module versions are pinned, lock file committed

## Cost impact

<!-- "None", or the recurring monthly delta and what is driving it. -->

## Rollback

<!-- How this gets undone. "Revert the commit" only counts if that is actually
     safe for stateful resources. -->
