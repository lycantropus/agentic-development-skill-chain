# Testing Anti-Patterns

For QA test-evidence review and the Simplicity Gate. Report confirmed findings
with evidence and a suggested correction; the finder does not edit code.

### 1. Testing Mock Behavior

Asserting on mock elements (e.g., `getByTestId('sidebar-mock')`).

**Detection:** Assertions prove only mock existence, not real component behavior.
Suggest testing the real behavior or removing the assertion.

### 2. Test-Only Methods in Production

Production classes expose `destroy()` or cleanup methods used only by tests.

**Detection:** The method exists only to support tests and has no production,
public API, or framework lifecycle contract. Test-only in-repo callers alone
are not sufficient evidence.
Suggest moving test-only support to test utilities.

### 3. Mocking Without Understanding Dependencies

Mocking a high-level method that has side effects the test depends on.

**Detection:** Compare the real method’s side effects with the state the assertion
requires. Flag mocks that remove a required side effect or hide missing setup.
Request a positive control with the real implementation when evidence is unclear.

### 4. Incomplete Mocks

Mocks contain only fields used by the immediate test; downstream code depends on omitted fields.

**Detection:** Compare the mock with the real data contract and downstream reads;
flag omitted fields that make the test unrepresentative. Suggest a complete fixture.

### 5. Tests as Afterthought

The completion report claims success without executed tests for changed behavior.

**Detection:** A changed behavior has no executed regression test or no evidence
that the test detects the failure. Request the missing evidence before accepting completion.

## Warning Signs of Bad Mocks

- Mock setup longer than test logic
- Mocking everything to make test pass
- Mocks missing methods real components have
- Test breaks when mock changes
- Can't explain why mock is needed

When these signals hide behavior, suggest integration coverage with real components.

