import lib.geometry as geo
from lib.geometry import Circle, Rect

shapes = [Circle(1), Rect(2, 3), geo.Circle(0.5)]
for s in shapes
    print "{s}: {geo.area(s):.2f}"
print "total: {geo.total(shapes):.2f}"
