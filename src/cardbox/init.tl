-- The policy side, as one module. `cardbox.cards` is a card's life (open → samples /
-- evals / checkpoints → close, and the fold that reads them back); the find DSL, the
-- alias rules and the prune rules join it here as the later steps land.

local type Cards = require("cardbox.cards")

local record cardbox
   cards: Cards
end

cardbox.cards = require("cardbox.cards")

function cardbox.version(): string
   return "0.1.0"
end

return cardbox
