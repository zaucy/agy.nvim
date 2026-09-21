local utils = require("agy.utils")
local transcript = require("agy.transcript")
local test_helpers = require("tests.test_helpers")

print("--- Testing Transcript Module ---")

-- 1. Test clean_user_content
local raw = "<USER_REQUEST>\nHello world\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\ninfo\n</ADDITIONAL_METADATA>"
local cleaned = transcript.clean_user_content(raw)
assert(cleaned == "Hello world", "Expected 'Hello world', got: " .. tostring(cleaned))
print("✓ clean_user_content passed")

-- 2. Test read_history with isolated mock environment
local tmp_dir, mock_cid = test_helpers.create_mock_environment()
local history = transcript.read_history(tmp_dir)
print("Found " .. #history .. " history entries in mock environment.")
assert(#history > 0, "Expected at least 1 history entry")
local first = history[1]
print(
	"Recent conversation: " .. first.conversation_id .. " (" .. first.relative_time .. "): " .. first.title:sub(1, 40)
)
assert(first.conversation_id == mock_cid, "conversation_id must match mock_cid")
print("✓ read_history passed")

-- 3. Test read_transcript for mock conversation
local steps = transcript.read_transcript(first.conversation_id, tmp_dir)
print("Steps in conversation " .. first.conversation_id .. ": " .. #steps)
assert(#steps == 4, "Expected 4 steps, got: " .. #steps)
print("✓ read_transcript passed")

-- 4. Test extract_model_from_steps
local model = transcript.extract_model_from_steps(steps)
assert(model == "Gemini 3.8 Flash (High)", "Expected extracted model 'Gemini 3.8 Flash (High)', got: " .. tostring(model))
print("✓ extract_model_from_steps passed")

print("ALL TRANSCRIPT TESTS PASSED!")
