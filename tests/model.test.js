const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("parseConfig defaults and round-trips", () => {
  assert.deepEqual(Model.parseConfig(""), Model.defaultConfig())
  assert.deepEqual(Model.parseConfig("not json"), Model.defaultConfig())

  const saved = Model.parseConfig(Model.serializeConfig({
    enabled: false,
    laptop: "eDP-1",
    primary: "desc:BNQ BenQ RD280U"
  }))
  assert.equal(saved.enabled, false)
  assert.equal(saved.laptop, "eDP-1")
  assert.equal(saved.primary, "desc:BNQ BenQ RD280U")
})

test("internal panel names and selectors", () => {
  assert.equal(Model.isInternalName("eDP-1"), true)
  assert.equal(Model.isInternalName("DP-3"), false)
  assert.equal(Model.selectorFor({ name: "eDP-1", description: "BOE Panel" }), "eDP-1")
  assert.equal(
    Model.selectorFor({ name: "DP-3", description: "BNQ BenQ RD280U 77R" }),
    "desc:BNQ BenQ RD280U 77R"
  )
  assert.equal(
    Model.monitorLabel({ name: "DP-3", description: "BNQ BenQ RD280U" }),
    "BNQ BenQ RD280U (DP-3)"
  )
})

test("affinity ids skip junk and sort", () => {
  assert.deepEqual(Model.parseAffinityIds("5\n1\n1\nnope\n2\n"), [1, 2, 5])
})

test("loader install is idempotent and reversible", () => {
  const original = "require(\"hypr.monitors\")\n"
  const once = Model.withLoader(original)
  const twice = Model.withLoader(once)
  assert.equal(once, twice)
  assert.equal(once.includes("seanpk.dock-workspaces"), true)
  assert.equal(once.includes("dock-workspaces.lua"), true)
  assert.equal(Model.needsLoader(once), false)
  assert.equal(Model.withoutLoader(once).includes("seanpk.dock-workspaces"), false)
  assert.equal(Model.withoutLoader(once).includes("require(\"hypr.monitors\")"), true)
})
