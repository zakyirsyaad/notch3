# Notch3 Animation, Onboarding, Recovery Input — Design QA

## Comparison target

- Source visual truth path: `/Users/mac/developer/notch3/docs/superpowers/plans/2026-08-20-notch3-animation-onboarding-recovery-input.md`
- Source artifact status: the plan is a textual interaction/geometry specification; it does not include a Figma node, mockup, screenshot, or other visual target.
- Implementation screenshot path (final collapsed native HUD): `/Users/mac/.codex/visualizations/2026/08/20/01a01ffe-65d3-7792-b2eb-1c0057729d32/notch3-final-native-state.png`
- Implementation screenshot path (final expanded native HUD): `/Users/mac/.codex/visualizations/2026/08/20/01a01ffe-65d3-7792-b2eb-1c0057729d32/notch3-final-expanded.png`
- Additional onboarding screenshot path (Create new state captured during the same implementation session): `/Users/mac/.codex/visualizations/2026/08/20/01a01ffe-65d3-7792-b2eb-1c0057729d32/notch3-after-click.png`

## Capture normalization

- Native desktop capture: 3360 x 2100 pixels.
- Logical desktop viewport: 1680 x 1050 points.
- Density: 2x Retina capture; no downsampling was applied because both implementation captures use the same native density.
- State: one final collapsed HUD capture, one final expanded HUD capture, and one additional expanded Create new onboarding capture. The 12/24-word import grid state was not captured successfully in the available desktop session.

## Evidence

### Full-view comparison

The implementation captures are openable and show the native Notch3 HUD and onboarding sheet. A source visual target at the same viewport and state is unavailable, so typography, spacing, colors, imagery, and copy cannot be judged as visual fidelity against the intended design.

### Focused-region comparison

Not performed. The source artifact has no visual region to align against, and the available implementation captures do not include a valid import-grid state.

## Findings

- [P1] Missing source visual target.
  Location: plan handoff.
  Evidence: the supplied plan specifies motion, geometry, onboarding behavior, and input semantics but contains no visual mockup or source capture.
  Impact: a visual QA pass cannot distinguish intentional visual design from implementation drift.
  Fix: provide a Figma node, mockup, or same-state source screenshot for the collapsed HUD, expanded drawer, and import-grid onboarding states.

- [P2] Import-grid visual state was not captured.
  Location: native onboarding import flow.
  Evidence: the native session produced a valid collapsed HUD and Create new onboarding capture, but not the Import existing 12/24-word grid state.
  Impact: the most substantial new UI surface remains unverified by visual evidence.
  Fix: rerun the native capture with the Import existing state selected at the same 1680 x 1050 logical viewport after a source visual target is supplied.

## Comparison history

1. Initial pass: blocked because no source visual target was supplied.
2. Implementation capture: collapsed HUD and Create new onboarding states opened successfully; no source comparison was possible.
3. Post-fix code review: animation, onboarding lifetime, rapid-open guarding, and stale-paste submission fixes were reviewed and verified by build/test evidence, but this does not replace visual comparison.

## Implementation checklist

- [x] Capture the native implementation at a fixed Retina viewport.
- [x] Record logical viewport and density normalization.
- [x] Record the unavailable source visual target instead of claiming visual parity.
- [ ] Supply source visuals and repeat full-view/focused-region comparison.
- [ ] Capture and compare the Import existing 12/24-word grid state.

## Follow-up polish

Once source visuals are available, compare font optical weight, grid density, field alignment, segmented-control proportions, error-card wrapping, and reduced-motion presentation at the same native viewport.

final result: blocked
