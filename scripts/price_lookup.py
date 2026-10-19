"""Print Bedrock price-list rows whose attributes mention any of the given substrings.

Usage: python scripts/price_lookup.py <price-list.json> [<price-list.json> ...] -- <substr> [<substr> ...]
Input files are `aws pricing get-products --service-code AmazonBedrock* --output json` dumps.
"""
import json
import sys

sep = sys.argv.index("--")
files, needles = sys.argv[1:sep], [n.lower() for n in sys.argv[sep + 1:]]
for f in files:
    for raw in json.load(open(f))["PriceList"]:
        p = json.loads(raw)
        attrs = p["product"]["attributes"]
        text = json.dumps(attrs).lower()
        if not all(n in text for n in needles):
            continue
        for term in p["terms"].get("OnDemand", {}).values():
            for dim in term["priceDimensions"].values():
                usd = dim["pricePerUnit"].get("USD")
                print(f'{attrs.get("usagetype","")}\t{attrs.get("inferenceType", attrs.get("feature",""))}\t'
                      f'{usd}/{dim["unit"]}\t{dim["description"][:110]}')
