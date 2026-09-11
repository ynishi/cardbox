-- The policy side. Step 1 is the mechanism only, so this is a placeholder the later
-- steps grow into: `cards.open` / `append_samples` / `record_eval` / `save_checkpoint`
-- / `close`, the find DSL, and the prune rules all land here, above `require("store")`.

local record cardbox
end

function cardbox.version(): string
   return "0.1.0"
end

return cardbox
