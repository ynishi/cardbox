local record host
   record Point
      x: number
      y: number
   end
   greet: function(self: host, who: string): string
   scale: function(self: host, p: Point, k: number): Point
end

return host
