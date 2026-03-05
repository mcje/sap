# Sap Manual Testing Guide

This document describes how to set up test environments and verify sap functionality through command sequences.

## Test Directory Setup

```bash
# Create test directory structure
setup_test_dir() {
    local base="${1:-/tmp/sap-test}"
    rm -rf "$base"
    mkdir -p "$base/dir1/sub1"
    mkdir -p "$base/dir1/sub2"
    mkdir -p "$base/dir2/nested/deep"
    mkdir -p "$base/dir3"

    touch "$base/root_file.txt"
    touch "$base/dir1/file1.txt"
    touch "$base/dir1/file2.txt"
    touch "$base/dir1/sub1/a.txt"
    touch "$base/dir1/sub1/b.txt"
    touch "$base/dir1/sub2/c.txt"
    touch "$base/dir2/nested/deep/deep_file.txt"
    touch "$base/dir2/other.txt"
    touch "$base/dir3/solo.txt"
    touch "$base/.hidden_file"
    mkdir -p "$base/.hidden_dir"
    touch "$base/.hidden_dir/secret.txt"

    echo "Test directory created at $base"
    ls -laR "$base"
}

setup_test_dir /tmp/sap-test
```

## Running Sap

```vim
:Sap /tmp/sap-test
```

Or from command line:
```bash
nvim -c "Sap /tmp/sap-test"
```

## Test Sequences

Each test sequence describes:
- **Setup**: Initial state/actions
- **Action**: What to do
- **Expected**: What should happen
- **Verify**: How to confirm it worked

---

### Test 1: Basic Collapse/Expand Preserves Structure

**Setup**: Open sap at `/tmp/sap-test`, expand `dir1`

**Action**:
1. Move cursor to `dir1/`
2. Press `<CR>` to collapse
3. Press `<CR>` to expand

**Expected**: All children of dir1 reappear exactly as before

**Verify**: Buffer should show:
```
sap-test/
    dir1/
        file1.txt
        file2.txt
        sub1/
        sub2/
    dir2/
    ...
```

---

### Test 2: Pending Create Survives Collapse/Expand

**Setup**: Open sap, expand `dir1`

**Action**:
1. Go to line under `dir1/` children
2. Add new line: `    newfile.txt` (same indent as siblings)
3. Collapse `dir1/` (press `<CR>` on dir1)
4. Expand `dir1/` (press `<CR>` again)
5. Save (`:w`)

**Expected**:
- After expand: `newfile.txt` should still appear
- On save: Should show `[CREATE] /tmp/sap-test/dir1/newfile.txt`

**Verify**: `ls /tmp/sap-test/dir1/` should show `newfile.txt` after confirming save

---

### Test 3: Pending Delete Survives Collapse/Expand

**Setup**: Open sap, expand `dir1`

**Action**:
1. Delete line for `file1.txt` (`dd`)
2. Collapse `dir1/`
3. Expand `dir1/`
4. Save (`:w`)

**Expected**:
- After expand: `file1.txt` should NOT appear (deletion preserved)
- On save: Should show `[DELETE] /tmp/sap-test/dir1/file1.txt`

**Verify**: `ls /tmp/sap-test/dir1/` should NOT show `file1.txt` after confirming

---

### Test 4: Move via Cut/Paste Survives Collapse/Expand

**Setup**: Open sap, expand both `dir1` and `dir2`

**Action**:
1. Go to `dir1/file1.txt`, delete line (`dd`)
2. Go to under `dir2/` children
3. Paste (`p`)
4. Collapse `dir2/`
5. Expand `dir2/`
6. Save (`:w`)

**Expected**:
- After expand: `file1.txt` should appear under `dir2/`
- On save: Should show `[MOVE] .../dir1/file1.txt -> .../dir2/file1.txt`

**Verify**: File should be in `dir2/` not `dir1/` after save

---

### Test 5: Copy via Yank/Paste

**Setup**: Open sap, expand `dir1`

**Action**:
1. Go to `dir1/file1.txt`, yank line (`yy`)
2. Move to after `dir1/file2.txt`
3. Paste (`p`)
4. Save (`:w`)

**Expected**:
- Two lines with same ID should appear (original + copy)
- On save: Should show `[COPY] .../file1.txt -> .../file1.txt` (or similar path)

**Verify**: Both files exist after save

---

### Test 6: Copy Then Delete Original = Move

**Setup**: Open sap, expand `dir1` and `dir2`

**Action**:
1. Go to `dir1/file1.txt`, yank (`yy`)
2. Go to under `dir2/`, paste (`p`)
3. Go back to original `dir1/file1.txt`, delete (`dd`)
4. Save (`:w`)

**Expected**:
- On save: Should show `[MOVE]` not `[COPY] + [DELETE]`

---

### Test 7: Rename via Edit

**Setup**: Open sap, expand `dir1`

**Action**:
1. Go to `dir1/file1.txt`
2. Change name to `renamed.txt` (edit the line, keep the ID prefix)
3. Save (`:w`)

**Expected**:
- On save: Should show `[MOVE] .../file1.txt -> .../renamed.txt`

**Verify**: `ls /tmp/sap-test/dir1/` shows `renamed.txt`

---

### Test 8: Move via Indent Change

**Setup**: Open sap, expand `dir1` including `sub1`

**Action**:
1. Go to `dir1/sub1/a.txt`
2. Unindent (`<<`) to move it to `dir1/`
3. Save (`:w`)

**Expected**:
- On save: Should show `[MOVE] .../sub1/a.txt -> .../dir1/a.txt`

---

### Test 9: Navigation Preserves Edits (set_root)

**Setup**: Open sap, expand `dir1`, delete `file1.txt`

**Action**:
1. Go to `dir1/`, press `<C-CR>` to set as root
2. Verify `file1.txt` is still deleted (not shown)
3. Press `<BS>` to go back to parent
4. Verify `file1.txt` is still deleted
5. Save (`:w`)

**Expected**:
- Deletion should persist through navigation
- On save: Should show `[DELETE] .../dir1/file1.txt`

---

### Test 10: Navigation Preserves Edits (parent)

**Setup**: Open sap at `/tmp/sap-test/dir1` (start deeper)

**Action**:
1. Delete `file1.txt`
2. Press `<BS>` to go to parent (`/tmp/sap-test`)
3. Expand `dir1/` again
4. Verify `file1.txt` is still deleted
5. Save (`:w`)

**Expected**: Deletion persists, save shows DELETE

---

### Test 11: Nested Collapse/Expand

**Setup**: Open sap, expand `dir1` and `dir1/sub1`

**Action**:
1. Delete `dir1/sub1/a.txt`
2. Collapse `sub1/`
3. Collapse `dir1/`
4. Expand `dir1/`
5. Expand `sub1/`
6. Verify `a.txt` is still deleted
7. Save (`:w`)

**Expected**: Nested collapse/expand preserves deletions at all levels

---

### Test 12: Create in Collapsed Directory

**Setup**: Open sap, `dir1` is collapsed

**Action**:
1. Expand `dir1/`
2. Add new file `newfile.txt`
3. Collapse `dir1/`
4. Save (`:w`)

**Expected**:
- On save: Should show `[CREATE] .../dir1/newfile.txt`
- File is created even though dir was collapsed at save time

---

### Test 13: Hidden Files Toggle

**Setup**: Open sap (hidden files not shown by default)

**Action**:
1. Press `h` to toggle hidden files
2. Verify `.hidden_file` and `.hidden_dir/` appear
3. Press `h` again
4. Verify they disappear
5. Edits to hidden files should persist through toggle

---

### Test 14: Refresh Discards Pending Edits

**Setup**: Open sap, expand `dir1`, delete `file1.txt`

**Action**:
1. Press `R` to refresh
2. Verify `file1.txt` reappears (deletion discarded)
3. Save (`:w`)

**Expected**: "sap: no changes" message (refresh cleared pending edits)

---

### Test 15: Multiple Operations Combined

**Setup**: Open sap, expand `dir1`, `dir2`, `dir1/sub1`

**Action**:
1. Create `dir1/new.txt`
2. Delete `dir1/file1.txt`
3. Move `dir1/file2.txt` to `dir2/`
4. Copy `dir1/sub1/a.txt` to `dir3/`
5. Rename `dir2/other.txt` to `dir2/renamed.txt`
6. Collapse and expand various directories
7. Navigate with set_root and parent
8. Save (`:w`)

**Expected**: All operations should be preserved and shown correctly:
- `[CREATE] .../dir1/new.txt`
- `[DELETE] .../dir1/file1.txt`
- `[MOVE] .../dir1/file2.txt -> .../dir2/file2.txt`
- `[COPY] .../dir1/sub1/a.txt -> .../dir3/a.txt`
- `[MOVE] .../dir2/other.txt -> .../dir2/renamed.txt`

---

## Running Automated Tests

**Run all tests (integration + unit):**
```bash
./tests/run_integration.sh
```

**Run integration tests only (real Neovim with keystrokes):**
```bash
nvim --headless -u tests/minimal_init.lua -l tests/integration_runner.lua
```

**Run unit tests only:**
```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

**Run surgical rendering tests specifically:**
```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/sap/surgical_spec.lua"
```

### Integration Test Coverage (integration_runner.lua)

The integration runner opens a real Neovim session and tests:
1. Initial render shows root and children
2. Expand directory with `<CR>`
3. Collapse directory with `<CR>`
4. Re-expand shows same content
5. Delete file with `dd`
6. Delete survives collapse/expand cycle
7. Create new file by adding line
8. New file survives collapse/expand
9. Rename by editing line
10. Rename survives collapse/expand
11. Expand nested directory
12. Nested collapse/expand preserves edits
13. Set root with `<C-CR>`
14. Go to parent with `<BS>`
15. Edits preserved through set_root/parent cycle

The `surgical_spec.lua` tests verify:
- Collapse/expand preserves buffer structure
- Pending creates survive collapse/expand
- Pending deletes survive collapse/expand
- Line edits (renames) survive collapse/expand
- Moves via indent change survive collapse/expand
- Nested collapse/expand works correctly
- Navigation (set_root, parent) preserves edits
- Hidden content storage and retrieval

## Custom Test Script Example

For additional automated verification:

```lua
-- tests/sap/integration_spec.lua
local function setup_test_dir()
    local base = "/tmp/sap-integration-test"
    vim.fn.system("rm -rf " .. base)
    vim.fn.mkdir(base .. "/dir1/sub1", "p")
    vim.fn.mkdir(base .. "/dir2", "p")
    vim.fn.writefile({}, base .. "/dir1/file1.txt")
    vim.fn.writefile({}, base .. "/dir1/file2.txt")
    vim.fn.writefile({}, base .. "/dir1/sub1/a.txt")
    vim.fn.writefile({}, base .. "/dir2/other.txt")
    return base
end

describe("sap integration", function()
    local base, bufnr

    before_each(function()
        base = setup_test_dir()
        bufnr = require("sap.buffer").create(base)
        vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
        vim.fn.system("rm -rf " .. base)
    end)

    it("should preserve creates through collapse/expand", function()
        local state = require("sap.buffer").get_state(bufnr)
        local render = require("sap.render")

        -- Expand dir1
        local dir1 = state:get_by_path(base .. "/dir1")
        render.expand(bufnr, state, dir1)

        -- Find line after dir1's children and add new file
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        -- ... add line for newfile.txt ...

        -- Collapse and expand
        render.collapse(bufnr, state, dir1)
        render.expand(bufnr, state, dir1)

        -- Sync and check pending creates
        require("sap.buffer").sync(bufnr)
        assert.is_not_nil(state.pending_creates[base .. "/dir1/newfile.txt"])
    end)
end)
```

## Debugging Tips

1. **Check state**: `:lua print(vim.inspect(require("sap.buffer").get_state(vim.api.nvim_get_current_buf())))`

2. **Check pending edits**:
   ```lua
   :lua local s = require("sap.buffer").get_state(0); print("deletes:", vim.inspect(s.pending_deletes)); print("moves:", vim.inspect(s.pending_moves)); print("creates:", vim.inspect(s.pending_creates))
   ```

3. **Check hidden content**:
   ```lua
   :lua local s = require("sap.buffer").get_state(0); print(vim.inspect(s.hidden_content))
   ```

4. **Force sync**:
   ```lua
   :lua require("sap.buffer").sync(vim.api.nvim_get_current_buf())
   ```

5. **Parse buffer**:
   ```lua
   :lua local p = require("sap.parser"); local s = require("sap.buffer").get_state(0); print(vim.inspect(p.parse_buffer(0, s.root_path)))
   ```
