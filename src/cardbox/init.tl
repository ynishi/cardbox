-- The policy side. `cardbox.cards` is the whole surface: a card's life (open → samples /
-- evals / checkpoints → close), the reads over it (get / list / find / lineage), the
-- aliases that name a card and the promotion rule that moves one, and the refusals any of
-- them answer with, and the prune rules that say what may be removed and in what order.
--
-- `cardbox.find` is where the read half is written — the column and operator whitelists,
-- the SQL builder, the lineage walk — and `cardbox.alias` is where the alias half is.
-- Both are exposed under their own names so that a caller who only reads, or only names
-- things, can require only what they use. `cards` re-exports the same functions, and they
-- are the same functions rather than copies of them.

local type Aliases = require("cardbox.alias")
local type Cards = require("cardbox.cards")
local type Find = require("cardbox.find")
local type Prune = require("cardbox.prune")

local record cardbox
   cards: Cards
   find: Find
   alias: Aliases
   prune: Prune
end

cardbox.cards = require("cardbox.cards")
cardbox.find = require("cardbox.find")
cardbox.alias = require("cardbox.alias")
cardbox.prune = require("cardbox.prune")

function cardbox.version(): string
   return "0.1.0"
end

return cardbox
