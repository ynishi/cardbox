-- The policy side. `cardbox.cards` is the whole surface: a card's life (open → samples /
-- evals / checkpoints → close), the reads over it (get / list / find / lineage), and the
-- refusals either half answers with. The alias rules and the prune rules join it here as
-- the later steps land.
--
-- `cardbox.find` is where the read half is written — the column and operator whitelists,
-- the SQL builder, the lineage walk — and it is exposed under its own name so that a
-- caller who only reads can require only that. `cards` re-exports the same four functions,
-- and they are the same functions rather than copies of them.

local type Cards = require("cardbox.cards")
local type Find = require("cardbox.find")

local record cardbox
   cards: Cards
   find: Find
end

cardbox.cards = require("cardbox.cards")
cardbox.find = require("cardbox.find")

function cardbox.version(): string
   return "0.1.0"
end

return cardbox
