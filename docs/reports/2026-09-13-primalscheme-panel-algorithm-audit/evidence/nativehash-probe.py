from primalschemers import FKmer

x = FKmer([b"ACGTACGTACGTACGTACG"], 19, [1])
print(hash(x))
