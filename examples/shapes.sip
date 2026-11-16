type Shape = Circle(r float) | Rect(w float, h float) | Triangle(b float, h float)

fn area(s Shape) float = match s
    Circle(r) -> pi * r * r
    Rect(w, h) -> w * h
    Triangle(b, h) -> 0.5 * b * h

for s in [Circle(1.0), Rect(2, 3), Triangle(4, 5)]
    print "{s}: {area(s):.2f}"
