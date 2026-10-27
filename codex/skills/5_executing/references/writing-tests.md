# Writing Tests

Reference for writing effective tests during TDD. Load when writing or changing tests, adding mocks, or when stuck.

## Good Tests

| Quality | Good | Bad |
|---------|------|-----|
| Minimal | One behavior per test | `test('validates email and domain and whitespace')` |
| Clear | Name describes behavior | `test('test1')` |
| Real | Tests actual code | Tests mock existence |

**Good example:**
```typescript
test('retries failed operations 3 times', async () => {
  let attempts = 0;
  const operation = () => {
    attempts++;
    if (attempts < 3) throw new Error('fail');
    return 'success';
  };
  const result = await retryOperation(operation);
  expect(result).toBe('success');
  expect(attempts).toBe(3);
});
```

**Bad example:**
```typescript
test('retry works', async () => {
  const mock = jest.fn()
    .mockRejectedValueOnce(new Error())
    .mockResolvedValueOnce('success');
  await retryOperation(mock);
  expect(mock).toHaveBeenCalledTimes(2); // tests mock, not behavior
});
```

## Test Levels and Coverage

Aim for high test coverage. Every new function, method, branch, and edge case should have a test. When in doubt, write the test.

### Unit Tests

Test one function/method in isolation. The foundation of coverage.

- Fast, deterministic, no external dependencies (DB, network, filesystem)
- Mock only external boundaries (APIs, databases, file I/O) — never mock the thing under test
- Cover: happy path, edge cases, error cases, boundary values, invalid inputs
- Every public function/method gets at least one unit test
- Every branch (if/else, switch, ternary) should be exercised

```typescript
// Test happy path AND edge cases for the same function
test('parseAge returns number for valid input', () => {
  expect(parseAge('25')).toBe(25);
});
test('parseAge returns 0 for zero', () => {
  expect(parseAge('0')).toBe(0);
});
test('parseAge throws for negative', () => {
  expect(() => parseAge('-1')).toThrow('Age must be positive');
});
test('parseAge throws for non-numeric', () => {
  expect(() => parseAge('abc')).toThrow('Invalid number');
});
test('parseAge throws for empty string', () => {
  expect(() => parseAge('')).toThrow('Age required');
});
```

### Integration Tests

Test components working together with real dependencies where practical.

- Use real implementations, not mocks (real DB with test data, real API clients against test servers)
- Cover: data flow between modules, API request/response cycles, database read/write roundtrips, component rendering with real children
- Slower than unit tests — write fewer but cover critical paths

```typescript
test('creating a user persists to DB and returns from API', async () => {
  const res = await request(app).post('/api/users').send({ name: 'Alice' });
  expect(res.status).toBe(201);

  const user = await db.users.findById(res.body.id);
  expect(user.name).toBe('Alice');
});
```

### When to Use Which

| Use unit tests for | Use integration tests for |
|---|---|
| Pure logic, calculations, transformations | Wiring between components |
| Input validation, parsing | API endpoints end-to-end |
| Error handling branches | Database operations (CRUD roundtrips) |
| Edge cases and boundary values | Authentication/authorization flows |
| Individual component rendering | Multi-component interactions |

### Coverage Goal

- Every public function: at least happy path + one error case
- Every conditional branch: exercised by a test
- Every edge case from the spec: has a dedicated test
- Prefer many small focused tests over few large ones — easier to diagnose failures
- If a bug is found later, write a regression test BEFORE fixing it

## Evidence Rules

Binding for every test an implementer, the Outer Ralph or a gate relies on.

- Run it and read the output; a test that was not run is not evidence.
- A test that depends on state outside itself (provider rate budget, suite order, clock) establishes or asserts that state itself. Never accept green because neighbouring tests primed the bucket or fixture.
- "Nothing happened" is weak evidence: add a positive control proving the valid session/input/path would have worked. The same holds for gate commands (`complexity_cmd`, `arch_rules_cmd`, `mutation_cmd`).
- Polling matchers must observe the transition; one that can pass on its first attempt proves nothing.
- Inside the shared-resource lock a test must not acquire the lock again. Node `--test` workers do not preserve inherited file descriptors: when a `node:test` entry point detects ownership through a descriptor, run it directly with `node path/to/test.mjs` and verify the selected-test count.
- Stuck after 3 attempts: escalate to the lead instead of guessing.

## When Stuck

| Problem | Solution |
|---------|----------|
| Don't know how to test | Write the wished-for API first. Write the assertion first. |
| Test too complicated | Design too complicated. Simplify the interface. |
| Must mock everything | Code too coupled. Use dependency injection. |
| Test setup huge | Extract helpers. Still complex? Simplify design. |

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Too simple to test" | Simple code breaks. Test takes 30 seconds. |
| "I'll test after" | Tests passing immediately prove nothing. |
| "Already manually tested" | Ad-hoc is not systematic. No record, can't re-run. |
| "Keep code as reference" | You'll adapt it. That's testing after. Delete means delete. |
| "TDD will slow me down" | TDD is faster than debugging. |

## Verification Checklist

Before marking a task complete:

- [ ] Every new function/method has a test (unit test minimum)
- [ ] Every conditional branch is exercised by a test
- [ ] Watched each test fail before implementing
- [ ] Each test failed for expected reason
- [ ] Wrote minimal code to pass each test
- [ ] All tests pass (unit + integration)
- [ ] Output clean (no errors, warnings)
- [ ] Tests use real code (mocks only at external boundaries)
- [ ] Edge cases, error cases, and boundary values covered
- [ ] Critical paths have integration tests
- [ ] Bug found? Regression test written before fix
