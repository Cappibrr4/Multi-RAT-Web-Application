import { Link } from 'react-router-dom';
import './NavBar.css';

export default function NavBar() {
  return (
    <nav className="navbar">
      <div className="navbar-container">
        <div className="navbar-brand">
          <h1>Multi-Path Schedulers Dashboard</h1>
          <p>Team ITP IS 8</p>
        </div>

        <div className="navbar-links">
          <Link to="/">Home</Link>
          <Link to="/scheduler">Scheduler Dashboard</Link>
          <Link to="/test">MPTCP Benchmark</Link>
          <Link to="/mpquic">MPQUIC Benchmark</Link>
        </div>
      </div>
    </nav>
  );
}
