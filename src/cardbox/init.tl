local record cardbox
   record Greeting
      who: string
      text: string
   end
end

function cardbox.greet(who: string): cardbox.Greeting
   return { who = who, text = "hello, " .. who }
end

return cardbox
