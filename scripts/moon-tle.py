import numpy as np
from datetime import datetime, timedelta
from skyfield.api import load
from tle_tailor import TLE_fitter  # pip install tle-tailor skyfield numpy

def generate_moon_tle():
    # 1. PULL DATA FROM URL
    # load() automatically downloads de421.bsp from NASA if not present locally
    print("Connecting to JPL/NASA to verify ephemeris data...")
    ts = load.timescale()
    eph = load('de421.bsp')  # Standard JPL high-accuracy planetary tables
    earth, moon = eph['earth'], eph['moon']

    # 2. COLLECT STATE VECTORS (TEME FRAME)
    # We need a 24-hour window for a stable daily fit
    start_dt = datetime.utcnow()
    times, states = [], []
    
    print(f"Sampling Moon vectors for {start_dt.date()}...")
    for i in range(0, 1440, 10):  # Every 10 minutes for 24 hours
        dt = start_dt + timedelta(minutes=i)
        t = ts.from_datetime(dt)
        
        # SGP4 requires TEME frame; Skyfield's (moon - earth) provides this
        pos_vel = (moon - earth).at(t)
        r = pos_vel.position.km
        v = pos_vel.velocity.km_per_s
        
        times.append(dt)
        states.append(np.concatenate([r, v]))

    # 3. TRANSFORM EPHEMERIS TO TLE
    # Fits a mean-element TLE to the osculating JPL vectors
    print("Iterating Least-Squares fit to generate TLE...")
    fitter = TLE_fitter(times, np.array(states))
    best_tle = fitter.fit()

    print("\n--- NEW MOON TLE ---")
    print(f"MOON\n{best_tle.line1}\n{best_tle.line2}")
    
    # 4. SAVE TO FILE FOR SOFTWARE
    with open("moon_current.tle", "w") as f:
        f.write(f"MOON\n{best_tle.line1}\n{best_tle.line2}")
    print("\nTLE saved to 'moon_current.tle'")

if __name__ == "__main__":
    generate_moon_tle()

