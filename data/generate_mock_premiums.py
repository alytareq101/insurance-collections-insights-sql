"""
Generate a MOCK insurance premium installments report with the full
broker collection chain:

  Weekly export -> Breakdown requested -> received -> confirmed
  -> Invoice received -> Sent to client (via Account Manager)
  -> Client pays (POP received) -> Receipt from insurer -> Settled in Odoo

The column layout mimics an Odoo outstanding-premiums export plus one date
per process step. Every insurer, customer, product, policy number and amount
is fictional. No real client data is used.

Output: mock_premium_report.xlsx
Run:    python generate_mock_premiums.py   (needs: pip install openpyxl)
"""

import random
from datetime import date, timedelta
from openpyxl import Workbook

random.seed(77)                 # same "random" data every run -> reproducible
AS_OF = date(2026, 11, 17)      # "today": steps after this date are still blank

# ---------------- Process assumptions (from the real workflow) ----------------
REQUEST_LEAD_WD = 14            # request breakdown 14 working days before due
LATE_REQUEST_RATE = 0.12        # sometimes a due is caught late in the weekly review
INVOICE_ERROR_SHARE = 0.5      # invoices are wrong about half as often as breakdowns
ERROR_DELAY_WD = (2, 4)         # extra working days when a document is wrong
STUCK_RATE = 0.08               # assumption: some clients don't pay (dispute / cash issues)
SLOW_RECEIPT_RATE = 0.25        # assumption: insurer sometimes slow to confirm money arrived

# Insurers: (extra working days on top of the normal 1-2 day turnaround,
#            how often their breakdown/invoice is wrong)
INSURERS = {
    "Nile Shield Insurance": (0, 0.20), "Pyramid Mutual": (0, 0.30),
    "Sphinx General": (1, 0.25), "Crescent Takaful": (1, 0.45),
    "Lotus Life & General": (2, 0.35), "Delta Assurance": (3, 0.55),
    "Atlas Re-Assurance": (3, 0.40), "Red Sea Cover": (5, 0.60),
}
MEDICAL_ERROR_FACTOR = 1.25     # member lists are complex -> more errors than Life
LIFE_ERROR_FACTOR = 0.6
INSURER_STALL_RATE = 0.04       # assumption: insurer ignores a request, needs chasing
FINANCE_BACKLOG_RATE = 0.10     # assumption: settlement sometimes waits in finance
YEAR_END_MONTHS = (12, 1)       # assumption: holidays / budget close slow everyone down

# Client payment behaviour (working days from receiving invoice to paying)
PAYER_PROFILES = [("normal", 0.70, (1, 7)),     # typical: 1-7 days
                  ("slow", 0.22, (5, 20)),      # assumption: some groups pay slowly
                  ("very slow", 0.08, (20, 45))]

PRODUCTS = {
    "Medical": ["Group Medical - Gold", "Group Medical - Silver",
                "Group Medical - Basic", "Individual Medical Plus",
                "Senior Care Medical"],
    "Life":    ["Group Life", "Group Life & Disability",
                "Credit Life", "Individual Term Life"],
}
GROUP_A = ["Horizon", "Cedar", "Falcon", "Oasis", "Atlas", "Crescent",
           "Papyrus", "Granite", "Zenith", "Riverside", "Sahara", "Orbit"]
GROUP_B = ["Holding", "Group", "Industries", "Investments"]
SUB_B = ["Trading", "Logistics", "Foods", "Textiles", "Pharma", "Tech",
         "Construction", "Motors", "Packaging", "Clinics", "Hotels", "Schools"]
SUFFIX = ["Co.", "LLC", "S.A.E."]
POLICY_TAGS = ["Staff", "Mgmt", "Renewal", "Add"]
PLANS = {1: 12, 2: 6, 4: 3, 12: 1}   # installments per year -> months apart


# ---------------- Date helpers ----------------
def is_workday(d):
    return d.weekday() not in (4, 5)          # Egypt weekend: Friday & Saturday


def add_wd(d, n):
    """Add (or subtract) n working days."""
    step = 1 if n >= 0 else -1
    while n != 0:
        d += timedelta(days=step)
        if is_workday(d):
            n -= step
    return d


def thursday_on_or_before(d):
    return d - timedelta(days=(d.weekday() - 3) % 7)


def add_months(d, months):
    m = d.month - 1 + months
    return date(d.year + m // 12, m % 12 + 1, min(d.day, 28))


def upto_today(*dates):
    """Blank out every step from the first one that is after AS_OF."""
    out, blank = [], False
    for d in dates:
        blank = blank or d > AS_OF
        out.append(None if blank else d)
    return out


# ---------------- One installment through the chain ----------------
def run_chain(due, insurer, payer_days, ins_type):
    extra, err = INSURERS[insurer]
    err *= MEDICAL_ERROR_FACTOR if ins_type == "Medical" else LIFE_ERROR_FACTOR
    year_end = due.month in YEAR_END_MONTHS
    if year_end:
        extra += 1

    # Weekly Thursday review picks up dues ~14 working days ahead
    requested = thursday_on_or_before(add_wd(due, -REQUEST_LEAD_WD))
    if random.random() < LATE_REQUEST_RATE:
        requested += timedelta(weeks=random.choice([1, 2]))     # caught late

    bd_received = add_wd(requested, random.randint(1, 2) + random.randint(0, extra)
                         + (random.randint(8, 25) if random.random() < INSURER_STALL_RATE else 0))
    bd_issue = random.random() < err
    bd_confirmed = add_wd(bd_received, random.randint(1, 2)
                          + (random.randint(*ERROR_DELAY_WD) if bd_issue else 0))

    inv_received = add_wd(bd_confirmed, random.randint(1, 2) + random.randint(0, extra)
                          + (random.randint(8, 25) if random.random() < INSURER_STALL_RATE else 0))
    inv_issue = random.random() < err * INVOICE_ERROR_SHARE
    sent_to_client = add_wd(inv_received, random.randint(*ERROR_DELAY_WD) if inv_issue else 0)

    pop_received = add_wd(sent_to_client, random.randint(*payer_days)
                          + (random.randint(1, 3) if year_end else 0))
    if random.random() < STUCK_RATE:                     # dispute / cash problem:
        pop_received = (date(2099, 1, 1) if random.random() < 0.12     # never paid
                        else add_wd(pop_received, random.randint(20, 60)))  # paid very late
    receipt = add_wd(pop_received, random.randint(1, 2) + random.randint(0, extra)
                     + (random.randint(5, 20) if random.random() < SLOW_RECEIPT_RATE else 0))
    settled = add_wd(receipt, random.randint(1, 2)
                     + (random.randint(5, 15) if random.random() < FINANCE_BACKLOG_RATE else 0))

    dates = upto_today(requested, bd_received, bd_confirmed, inv_received,
                       sent_to_client, pop_received, receipt, settled)
    # issue flags only make sense once that document has been reviewed
    bd_flag = ("Yes" if bd_issue else "No") if dates[2] else None
    inv_flag = ("Yes" if inv_issue else "No") if dates[4] else None
    status = "Paid" if dates[7] else "Outstanding"   # Odoo only flips at settlement
    return status, dates, bd_flag, inv_flag


def build_customers():
    """~25 key-account groups, each owning 1-4 customers, with a payer profile."""
    customers, used = [], set()
    while len({c["key"] for c in customers}) < 20:
        group = f"{random.choice(GROUP_A)} {random.choice(GROUP_B)}"
        if group in used:
            continue
        used.add(group)
        profile = random.choices(PAYER_PROFILES, [p[1] for p in PAYER_PROFILES])[0]
        base, n_subs = group.split()[0], random.choice([1, 1, 2, 3, 4])
        for _ in range(n_subs):
            name = group if n_subs == 1 else \
                f"{base} {random.choice(SUB_B)} {random.choice(SUFFIX)}"
            if n_subs > 1 and name in used:
                continue
            used.add(name)
            customers.append({"name": name, "key": group, "pay_days": profile[2]})
    return customers


def main():
    rows, seq = [], 0
    for cust in build_customers():
        for _ in range(random.choice([1, 1, 2])):           # 1-2 policies per customer
            ins_type = random.choice(["Medical", "Medical", "Life"])
            product = random.choice(PRODUCTS[ins_type])
            insurer = random.choice(list(INSURERS))
            n_inst = random.choice([1, 2, 4, 4, 12])
            gross_annual = random.choice([random.randint(20_000, 300_000),
                                          random.randint(300_000, 2_000_000),
                                          random.randint(2_000_000, 7_500_000)])
            net_ratio = random.uniform(0.86, 1.0)            # net = gross - fees/tax
            # first policy year starts Dec 2024 - Nov 2025, then renews once
            eff_from = date(2024, 12, 1) + timedelta(days=random.randint(0, 364))

            for term in range(2):                            # original + renewal
                seq += 1
                policy = (f"{random.randint(1, 4)}/{1 if ins_type == 'Life' else 2}/"
                          f"{random.randint(100, 999)}/{seq:04d}")
                if term == 1 and random.random() < 0.3:
                    policy += " - Renewal"
                elif random.random() < 0.08:
                    policy += " - " + random.choice(POLICY_TAGS)
                eff_to = add_months(eff_from, 12) - timedelta(days=1)

                for i in range(n_inst):
                    due = add_months(eff_from, i * PLANS[n_inst])
                    gross = round(gross_annual / n_inst, 2)
                    status, d, bd_flag, inv_flag = run_chain(due, insurer,
                                                             cust["pay_days"], ins_type)
                    rows.append([insurer, cust["name"], due, policy,
                                 round(gross * net_ratio, 2), ins_type, product,
                                 cust["key"], gross, eff_from, eff_to, status,
                                 d[0], d[1], bd_flag, d[2], d[3], inv_flag,
                                 d[4], d[5], d[6], d[7]])

                eff_from = add_months(eff_from, 12)          # renewal year
                gross_annual = round(gross_annual * random.uniform(1.0, 1.15))

    # ---------------- Realistic export quirks (cleaned on Day 2) ----------------
    for r in random.sample(rows, 3):          # credit notes / refunds
        r[4], r[8] = round(-abs(r[4]) * 0.1, 2), round(-abs(r[8]) * 0.1, 2)
    for r in random.sample(rows, 2):          # missing key account (Odoo exports False)
        r[7] = False
    for r in random.sample(rows, 6):          # extra spaces in customer names
        r[1] = "  " + r[1] + " "
    rows += [list(r) for r in random.sample(rows, 3)]     # duplicate lines
    random.shuffle(rows)
    rows.sort(key=lambda r: r[0])             # Odoo-style: grouped by insurer

    headers = ["Insurer/Name", "Customer/Name", "Premium Date", "Policy No.",
               "Net Premium", "Insurance Type", "Product/Display Name",
               "Key Account/Name", "Gross Premium", "Effective From",
               "Effective To", "Status",
               "Breakdown Requested", "Breakdown Received", "Breakdown Issue",
               "Breakdown Confirmed", "Invoice Received", "Invoice Issue",
               "Sent to Client", "POP Received", "Receipt Received", "Settled Date"]

    wb = Workbook()
    ws = wb.active
    ws.title = "Sheet1"
    ws.append(headers)
    for r in rows:
        ws.append(r)
    ws.append([])                             # stray rows at the bottom of the export
    for ins in random.sample(list(INSURERS), 5):
        ws.append([ins])

    date_cols = [i + 1 for i, h in enumerate(headers)
                 if "Date" in h or h.startswith(("Effective", "Breakdown R", "Breakdown C",
                                                 "Invoice R", "Sent", "POP", "Receipt"))]
    for c in date_cols:
        for row in ws.iter_rows(min_row=2, min_col=c, max_col=c):
            row[0].number_format = "yyyy-mm-dd"

    wb.save("mock_premium_report.xlsx")
    print(f"Wrote {len(rows)} installment rows to mock_premium_report.xlsx")


if __name__ == "__main__":
    main()
